"""User management over HTTP. SPEC.md §11 Phase 5, §12, §3.

The service layer is tested separately. What is checked here is what only the
route layer can get wrong: who may call these at all, that a PIN never comes
back out, and that an admin cannot lock themselves out of the box.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import db as db_module
from app.core.security import hash_pin
from app.main import app, get_session
from app.models.db import Base, User
from app.services.ingest import publish_card

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)

PINS = {"admin": "1357", "staff": "2468", "parttime": "4821"}
PHONES = {"admin": "0110000001", "staff": "0110000002", "parttime": "0110000003"}


@pytest.fixture
def client() -> Iterator[TestClient]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)

    with Session(engine) as setup:
        publish_card(setup, list_id="fair", payload=FAIR)
        for role, phone in PHONES.items():
            setup.add(
                User(
                    id=str(uuid.uuid4()),
                    name=role.title(),
                    phone=phone,
                    role=role,
                    pin_hash=hash_pin(PINS[role]),
                )
            )
        setup.commit()

    def override() -> Iterator[Session]:
        session = factory()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()

    app.dependency_overrides[get_session] = override
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()
    db_module.configure(db_module.DATABASE_URL)


def sign_in(client: TestClient, role: str) -> str:
    r = client.post(
        "/api/auth/login",
        json={
            "phone": PHONES[role],
            "pin": PINS[role],
            "device_id": str(uuid.uuid4()),
        },
    )
    assert r.status_code == 200, r.text
    return r.json()["token"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def person_id(client: TestClient, token: str, name: str) -> str:
    people = client.get("/api/people", headers=auth(token)).json()["people"]
    return next(p["id"] for p in people if p["name"] == name)


NEW_PERSON = {
    "name": "Ah Lian",
    "phone": "0129999999",
    "pin": "4821",
    "role": "parttime",
}


class TestWhoMayCallThese:
    @pytest.mark.parametrize(
        ("method", "path"),
        [
            ("get", "/api/people"),
            ("post", "/api/people"),
            ("post", "/api/people/x/pin"),
            ("post", "/api/people/x/deactivate"),
            ("post", "/api/people/x/reactivate"),
        ],
    )
    def test_nobody_without_a_token(
        self, client: TestClient, method: str, path: str
    ) -> None:
        # A body only where the verb takes one: TestClient.get rejects `json`.
        kwargs = {} if method == "get" else {"json": {}}
        r = getattr(client, method)(path, **kwargs)
        assert r.status_code == 401, r.text

    @pytest.mark.parametrize("role", ["staff", "parttime"])
    def test_not_staff_and_not_a_part_timer(
        self, client: TestClient, role: str
    ) -> None:
        # Creating users and revoking access is an admin power. Staff seeing
        # the roster would also hand the staff list to a handset that travels
        # to fairs, which is why there is no roster on the sign-in screen.
        token = sign_in(client, role)
        assert client.get("/api/people", headers=auth(token)).status_code == 403
        assert (
            client.post("/api/people", json=NEW_PERSON, headers=auth(token)).status_code
            == 403
        )


class TestTheRoster:
    def test_an_admin_sees_everybody(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.get("/api/people", headers=auth(token))
        assert r.status_code == 200
        assert {p["name"] for p in r.json()["people"]} == {
            "Admin",
            "Staff",
            "Parttime",
        }

    def test_no_hash_ever_comes_back(self, client: TestClient) -> None:
        # Nothing replayable leaves the server, and a hash is still something
        # to attack offline at leisure.
        token = sign_in(client, "admin")
        body = client.get("/api/people", headers=auth(token)).text
        assert "scrypt" not in body
        assert "pin_hash" not in body


class TestAddingSomebody:
    def test_they_can_sign_in_afterwards(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post("/api/people", json=NEW_PERSON, headers=auth(token))
        assert r.status_code == 201, r.text
        assert r.json()["name"] == "Ah Lian"

        signed_in = client.post(
            "/api/auth/login",
            json={
                "phone": "0129999999",
                "pin": "4821",
                "device_id": str(uuid.uuid4()),
            },
        )
        assert signed_in.status_code == 200, signed_in.text

    def test_the_pin_does_not_come_back(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post("/api/people", json=NEW_PERSON, headers=auth(token))
        assert "4821" not in r.text
        assert "pin" not in r.json()

    def test_a_weak_pin_is_refused_and_nobody_is_created(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            "/api/people",
            json={**NEW_PERSON, "pin": "0000"},
            headers=auth(token),
        )
        assert r.status_code == 422, r.text

        people = client.get("/api/people", headers=auth(token)).json()["people"]
        assert all(p["name"] != "Ah Lian" for p in people)

    def test_a_taken_phone_is_a_conflict_not_a_crash(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            "/api/people",
            json={**NEW_PERSON, "phone": PHONES["staff"]},
            headers=auth(token),
        )
        assert r.status_code == 409, r.text

    def test_an_unknown_role_is_refused_at_the_door(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            "/api/people",
            json={**NEW_PERSON, "role": "owner"},
            headers=auth(token),
        )
        assert r.status_code == 422, r.text


class TestLeavers:
    def test_deactivating_revokes_their_handset(self, client: TestClient) -> None:
        # §12: sessions never expire, so this is the control. The response says
        # how many handsets it stopped, because that is what somebody
        # deactivating a leaver actually wants to know.
        admin = sign_in(client, "admin")
        theirs = sign_in(client, "parttime")
        assert client.get("/api/auth/me", headers=auth(theirs)).status_code == 200

        target = person_id(client, admin, "Parttime")
        r = client.post(f"/api/people/{target}/deactivate", headers=auth(admin))
        assert r.status_code == 200, r.text
        assert r.json()["sessions_revoked"] == 1
        assert r.json()["person"]["is_active"] is False

        assert client.get("/api/auth/me", headers=auth(theirs)).status_code == 401

    def test_an_admin_cannot_deactivate_themselves(self, client: TestClient) -> None:
        # Locking the last admin out is a mistake nobody can undo from the app.
        # The only way back would be a trip to the server with a shell.
        admin = sign_in(client, "admin")
        me = person_id(client, admin, "Admin")

        r = client.post(f"/api/people/{me}/deactivate", headers=auth(admin))
        assert r.status_code == 422, r.text
        assert client.get("/api/auth/me", headers=auth(admin)).status_code == 200

    def test_an_unknown_user_is_a_404(self, client: TestClient) -> None:
        admin = sign_in(client, "admin")
        r = client.post(f"/api/people/{uuid.uuid4()}/deactivate", headers=auth(admin))
        assert r.status_code == 404

    def test_coming_back_still_means_signing_in_again(self, client: TestClient) -> None:
        admin = sign_in(client, "admin")
        theirs = sign_in(client, "parttime")
        target = person_id(client, admin, "Parttime")

        client.post(f"/api/people/{target}/deactivate", headers=auth(admin))
        r = client.post(f"/api/people/{target}/reactivate", headers=auth(admin))
        assert r.status_code == 200
        assert r.json()["is_active"] is True

        # The old handset stays out. One that was in somebody else's hands
        # must not silently start working again.
        assert client.get("/api/auth/me", headers=auth(theirs)).status_code == 401
        assert sign_in(client, "parttime")


class TestChangingAPin:
    def test_the_old_one_stops_working(self, client: TestClient) -> None:
        admin = sign_in(client, "admin")
        target = person_id(client, admin, "Parttime")

        r = client.post(
            f"/api/people/{target}/pin", json={"pin": "7788"}, headers=auth(admin)
        )
        assert r.status_code == 200, r.text

        old = client.post(
            "/api/auth/login",
            json={
                "phone": PHONES["parttime"],
                "pin": PINS["parttime"],
                "device_id": str(uuid.uuid4()),
            },
        )
        assert old.status_code == 401

        new = client.post(
            "/api/auth/login",
            json={
                "phone": PHONES["parttime"],
                "pin": "7788",
                "device_id": str(uuid.uuid4()),
            },
        )
        assert new.status_code == 200, new.text

    def test_a_weak_replacement_is_refused(self, client: TestClient) -> None:
        admin = sign_in(client, "admin")
        target = person_id(client, admin, "Parttime")

        r = client.post(
            f"/api/people/{target}/pin", json={"pin": "1111"}, headers=auth(admin)
        )
        assert r.status_code == 422, r.text
        # And the old one still works, so a refusal leaves nobody locked out.
        assert sign_in(client, "parttime")

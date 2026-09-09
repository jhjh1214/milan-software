"""The Property / Project / Unit Library over HTTP. SPEC.md Phase 8.

The service layer is tested separately (`test_library.py`). What is checked
here is what only the route layer can get wrong: that approval and
rejection are admin-only while drafting and submitting are not, and that a
bad id or a wrong-status action comes back as the right status code rather
than a 500.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import db as db_module
from app.core.security import hash_pin
from app.main import app, get_session
from app.models.db import Base, User

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
        json={"phone": PHONES[role], "pin": PINS[role], "device_id": str(uuid.uuid4())},
    )
    assert r.status_code == 200, r.text
    return r.json()["token"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def make_project(client: TestClient, token: str) -> str:
    r = client.post(
        "/api/projects",
        json={"name": "ABC Development", "area": "Ayer Keroh"},
        headers=auth(token),
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


OPENINGS = [
    {"label": "W1", "room": "Living", "nominal_w_tmm": 18000, "nominal_h_tmm": 24000},
]


class TestWhoMayCallThese:
    @pytest.mark.parametrize(
        ("method", "path"),
        [
            ("get", "/api/projects"),
            ("post", "/api/projects"),
            ("get", "/api/unit-types"),
            ("post", "/api/unit-types"),
            ("get", "/api/unit-types/x"),
            ("post", "/api/unit-types/x/submit"),
            ("post", "/api/unit-types/x/approve"),
            ("post", "/api/unit-types/x/reject"),
            ("post", "/api/unit-types/x/versions"),
        ],
    )
    def test_nobody_without_a_token(
        self, client: TestClient, method: str, path: str
    ) -> None:
        kwargs = {} if method == "get" else {"json": {}}
        r = getattr(client, method)(path, **kwargs)
        assert r.status_code == 401, r.text

    def test_a_part_timer_may_draft_and_submit(self, client: TestClient) -> None:
        token = sign_in(client, "parttime")
        project_id = make_project(client, token)

        r = client.post(
            "/api/unit-types",
            json={"project_id": project_id, "name": "Type B", "openings": OPENINGS},
            headers=auth(token),
        )
        assert r.status_code == 201, r.text
        unit_type_id = r.json()["unit_type"]["id"]

        r = client.post(f"/api/unit-types/{unit_type_id}/submit", headers=auth(token))
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "pending_review"

    @pytest.mark.parametrize("role", ["staff", "parttime"])
    def test_approving_and_rejecting_need_an_admin(
        self, client: TestClient, role: str
    ) -> None:
        admin_token = sign_in(client, "admin")
        project_id = make_project(client, admin_token)
        unit_type_id = client.post(
            "/api/unit-types",
            json={"project_id": project_id, "name": "Type B", "submit": True},
            headers=auth(admin_token),
        ).json()["unit_type"]["id"]

        token = sign_in(client, role)
        assert (
            client.post(
                f"/api/unit-types/{unit_type_id}/approve", headers=auth(token)
            ).status_code
            == 403
        )
        assert (
            client.post(
                f"/api/unit-types/{unit_type_id}/reject",
                json={"reason": "no"},
                headers=auth(token),
            ).status_code
            == 403
        )


class TestTheLifecycleEndToEnd:
    def test_draft_to_approved_carries_the_openings_and_rooms_through(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        project_id = make_project(client, token)

        created = client.post(
            "/api/unit-types",
            json={
                "project_id": project_id,
                "name": "Type B",
                "openings": OPENINGS,
                "rooms": [{"name": "Living", "nominal_area_mm2": 18_000_000}],
            },
            headers=auth(token),
        ).json()
        unit_type_id = created["unit_type"]["id"]
        assert created["unit_type"]["status"] == "draft"
        # Denormalised onto the row: the review queue says "ABC Development,
        # Type B" without a second request per row.
        assert created["unit_type"]["project_name"] == "ABC Development"
        assert created["versions"][0]["openings"][0]["label"] == "W1"
        assert created["versions"][0]["rooms"][0]["name"] == "Living"

        approved = client.post(
            f"/api/unit-types/{unit_type_id}/approve", headers=auth(token)
        )
        assert approved.status_code == 200, approved.text
        assert approved.json()["status"] == "approved"

        detail = client.get(
            f"/api/unit-types/{unit_type_id}", headers=auth(token)
        ).json()
        assert detail["versions"][0]["approved_by_user_id"] is not None

    def test_a_rejection_carries_the_reason_and_goes_back_to_draft(
        self, client: TestClient
    ) -> None:
        admin_token = sign_in(client, "admin")
        parttime_token = sign_in(client, "parttime")
        project_id = make_project(client, admin_token)

        unit_type_id = client.post(
            "/api/unit-types",
            json={
                "project_id": project_id,
                "name": "Type B",
                "openings": OPENINGS,
                "submit": True,
            },
            headers=auth(parttime_token),
        ).json()["unit_type"]["id"]

        r = client.post(
            f"/api/unit-types/{unit_type_id}/reject",
            json={"reason": "Window 1 looks too wide, please recheck"},
            headers=auth(admin_token),
        )
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "draft"

        detail = client.get(
            f"/api/unit-types/{unit_type_id}", headers=auth(admin_token)
        ).json()
        assert "recheck" in detail["versions"][0]["rejection_reason"]

    def test_a_wrong_status_action_is_409_not_500(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        project_id = make_project(client, token)
        unit_type_id = client.post(
            "/api/unit-types",
            json={"project_id": project_id, "name": "Type B"},
            headers=auth(token),
        ).json()["unit_type"]["id"]

        # Never submitted, so it cannot be rejected.
        r = client.post(
            f"/api/unit-types/{unit_type_id}/reject",
            json={"reason": "no"},
            headers=auth(token),
        )
        assert r.status_code == 409, r.text

    def test_an_unknown_project_is_404_not_500(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            "/api/unit-types",
            json={"project_id": str(uuid.uuid4()), "name": "Type B"},
            headers=auth(token),
        )
        assert r.status_code == 404, r.text

    def test_an_unknown_unit_type_is_404_not_500(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.get(f"/api/unit-types/{uuid.uuid4()}", headers=auth(token))
        assert r.status_code == 404, r.text

    def test_the_review_queue_is_filtered_by_status_on_the_wire(
        self, client: TestClient
    ) -> None:
        # The admin review screen's whole query: everything waiting on it.
        token = sign_in(client, "admin")
        project_id = make_project(client, token)
        client.post(
            "/api/unit-types",
            json={"project_id": project_id, "name": "Type A"},
            headers=auth(token),
        )
        pending = client.post(
            "/api/unit-types",
            json={"project_id": project_id, "name": "Type B", "submit": True},
            headers=auth(token),
        ).json()

        r = client.get("/api/unit-types?status=pending_review", headers=auth(token))
        assert r.status_code == 200, r.text
        names = [u["name"] for u in r.json()["unit_types"]]
        assert names == ["Type B"]
        row = r.json()["unit_types"][0]
        assert row["project_name"] == "ABC Development"
        assert row["id"] == pending["unit_type"]["id"]

    def test_the_review_queue_carries_the_actual_submission_not_just_its_name(
        self, client: TestClient
    ) -> None:
        # The admin has to see what was submitted to review it -- one request,
        # not one per row.
        token = sign_in(client, "admin")
        project_id = make_project(client, token)
        client.post(
            "/api/unit-types",
            json={
                "project_id": project_id,
                "name": "Type B",
                "openings": OPENINGS,
                "rooms": [{"name": "Living", "nominal_area_mm2": 18_000_000}],
                "submit": True,
            },
            headers=auth(token),
        )

        r = client.get("/api/unit-types?status=pending_review", headers=auth(token))
        row = r.json()["unit_types"][0]
        assert row["versions"][0]["openings"][0]["label"] == "W1"
        assert row["versions"][0]["rooms"][0]["name"] == "Living"

    def test_a_new_version_supersedes_the_old_openings_for_quoting_but_keeps_history(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        project_id = make_project(client, token)
        unit_type_id = client.post(
            "/api/unit-types",
            json={"project_id": project_id, "name": "Type B", "openings": OPENINGS},
            headers=auth(token),
        ).json()["unit_type"]["id"]
        client.post(f"/api/unit-types/{unit_type_id}/approve", headers=auth(token))

        r = client.post(
            f"/api/unit-types/{unit_type_id}/versions",
            json={
                "openings": [
                    {
                        "label": "W1",
                        "room": "Living",
                        "nominal_w_tmm": 19000,
                        "nominal_h_tmm": 24000,
                    }
                ],
                "note": "Developer revised the schedule",
            },
            headers=auth(token),
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["unit_type"]["status"] == "draft"
        assert len(body["versions"]) == 2
        assert body["versions"][0]["approved_at"] is not None
        assert body["versions"][1]["approved_at"] is None

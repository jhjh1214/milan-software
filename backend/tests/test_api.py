"""The HTTP surface. §9.1 and §9.2, over the wire this time.

The routes are thin, so these tests check the things only HTTP can get wrong:
status codes, the up-to-date short circuit, and that a retry is a 200 rather
than an error the device would keep retrying forever.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import db as db_module
from app.main import app, get_session
from app.models.db import Base
from app.services.ingest import publish_card

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)
STANDARD = json.loads(
    (ROOT / "shared" / "rate-card-standard.json").read_text(encoding="utf-8")
)


@pytest.fixture
def client() -> Iterator[TestClient]:
    # StaticPool with one shared connection: a plain sqlite:// engine gives
    # every connection its own private in-memory database, so the table the
    # fixture creates is invisible to the request handler.
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)

    with Session(engine) as setup:
        publish_card(setup, list_id="fair", payload=FAIR)
        publish_card(setup, list_id="standard", payload=STANDARD)
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


def a_quote(*, quote_id: str | None = None, total: int = 55200) -> dict:
    now = datetime.now(UTC).isoformat()
    return {
        "id": quote_id or str(uuid.uuid4()),
        "rate_card_version": 1,
        "tier": "standard",
        "language": "zh",
        "device_total_sen": total,
        "created_at": now,
        "updated_at": now,
        "device_id": str(uuid.uuid4()),
        "lines": [
            {
                "id": str(uuid.uuid4()),
                "sort_order": 0,
                "room": "客厅",
                "variant": "night_curtain",
                "material_key": None,
                "layer": "night",
                "width_tmm": 36576,
                "height_tmm": 27432,
                "raw_width": "12'",
                "raw_height": "9'",
                "quantity": 1,
                "device_total_sen": total,
            }
        ],
    }


class TestBundle:
    def test_it_serves_the_active_fair_card(self, client: TestClient) -> None:
        r = client.get("/api/bundle", params={"list_id": "fair"})
        assert r.status_code == 200
        body = r.json()
        assert body["rate_card_version"] == 1
        assert body["up_to_date"] is False
        assert len(body["payload"]["rules"]) == 77

    def test_it_serves_the_standard_card_separately(self, client: TestClient) -> None:
        r = client.get("/api/bundle", params={"list_id": "standard"})
        assert r.json()["rate_card_version"] == 101

    def test_a_current_device_gets_no_payload(self, client: TestClient) -> None:
        # §9.1. A fair's connection should not be spent re-downloading a card
        # the phone already has.
        r = client.get("/api/bundle", params={"list_id": "fair", "since_version": 1})
        body = r.json()
        assert body["up_to_date"] is True
        assert body["payload"] is None

    def test_a_stale_device_gets_the_whole_card(self, client: TestClient) -> None:
        # Replaced wholesale, never diffed.
        r = client.get("/api/bundle", params={"list_id": "fair", "since_version": 0})
        body = r.json()
        assert body["up_to_date"] is False
        assert body["payload"] is not None

    def test_an_unknown_list_is_rejected_by_validation(
        self, client: TestClient
    ) -> None:
        assert client.get("/api/bundle", params={"list_id": "nope"}).status_code == 422


class TestPush:
    def test_a_quote_is_accepted_and_repriced(self, client: TestClient) -> None:
        r = client.post("/api/quotes", json=a_quote())
        assert r.status_code == 200
        body = r.json()
        assert body["duplicate"] is False
        assert body["server_total_sen"] == 55200
        assert body["discrepancies"] == []

    def test_a_retry_is_a_success_not_an_error(self, client: TestClient) -> None:
        # §9.2. Treating a retry as a failure would have the outbox retry
        # forever, and the row would never drain.
        payload = a_quote()
        first = client.post("/api/quotes", json=payload)
        second = client.post("/api/quotes", json=payload)

        assert first.status_code == 200
        assert second.status_code == 200
        assert first.json()["duplicate"] is False
        assert second.json()["duplicate"] is True
        assert second.json()["server_total_sen"] == first.json()["server_total_sen"]

    def test_a_disagreement_still_returns_200(self, client: TestClient) -> None:
        # §9.4: accept the order, log the discrepancy. A 4xx here would lose a
        # sale the customer has already put a deposit on.
        r = client.post("/api/quotes", json=a_quote(total=55100))
        assert r.status_code == 200
        body = r.json()
        assert len(body["discrepancies"]) == 1
        assert body["discrepancies"][0]["server_total_sen"] == 55200
        assert body["discrepancies"][0]["device_total_sen"] == 55100

    def test_an_unknown_rate_card_version_is_a_conflict(
        self, client: TestClient
    ) -> None:
        payload = a_quote()
        payload["rate_card_version"] = 999
        assert client.post("/api/quotes", json=payload).status_code == 409

    def test_a_malformed_push_is_rejected_at_the_door(self, client: TestClient) -> None:
        payload = a_quote()
        del payload["lines"][0]["width_tmm"]
        assert client.post("/api/quotes", json=payload).status_code == 422

    def test_a_negative_dimension_is_rejected(self, client: TestClient) -> None:
        payload = a_quote()
        payload["lines"][0]["width_tmm"] = -1
        assert client.post("/api/quotes", json=payload).status_code == 422


def test_health(client: TestClient) -> None:
    assert client.get("/api/health").json() == {"status": "ok"}

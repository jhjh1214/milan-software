"""Inventory over HTTP. SPEC.md Phase 9.

The service layer is tested separately (`test_inventory.py`). What matters
here is what only the route layer can get wrong: every inventory action is
admin-only (§13 F2), and a bad id or a wrong-status action comes back as
the right status code rather than a 500.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import db as db_module
from app.core.security import hash_pin
from app.main import app, get_session
from app.models.db import Base, Order, OrderLine, User

PINS = {"admin": "1357", "staff": "2468", "parttime": "4821"}
PHONES = {"admin": "0110000001", "staff": "0110000002", "parttime": "0110000003"}

ORDER_ID = str(uuid.uuid4())
LINE_ID = str(uuid.uuid4())


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
        setup.add(
            Order(
                id=ORDER_ID,
                quote_id=str(uuid.uuid4()),
                channel="fair",
                pinned_rate_card_version=1,
                estimate_total_sen=99999,
                confirmed_at=datetime(2026, 9, 1, tzinfo=UTC),
            )
        )
        setup.add(
            OrderLine(
                id=LINE_ID,
                order_id=ORDER_ID,
                quote_line_id=str(uuid.uuid4()),
                sort_order=0,
                room="Living",
                variant="spc_4mm_1mm",
                layer="single",
                est_width_tmm=30480,
                applied_rule_id="spc-4mm-1mm",
                applied_rate_card_version=1,
                standard_rate_sen=1000,
                rate_sen=1000,
                billed_qty="100",
                billed_unit="sqft",
                line_total_sen=99999,
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


def make_material(client: TestClient, token: str, **overrides) -> dict:
    payload = {
        "family": "flooring",
        "variant_compat": ["spc_4mm_1mm"],
        "code": f"SPC-{uuid.uuid4().hex[:8]}",
        "names": {"zh": "SPC地板", "en": "SPC flooring", "ms": "Lantai SPC"},
        "uom": "box",
        "coverage_per_unit": "18",
        **overrides,
    }
    r = client.post("/api/materials", json=payload, headers=auth(token))
    assert r.status_code == 201, r.text
    return r.json()


class TestAdminOnly:
    """Every inventory route is admin-only (§13 F2's answer)."""

    def test_staff_cannot_create_a_material(self, client: TestClient) -> None:
        token = sign_in(client, "staff")
        r = client.post(
            "/api/materials",
            json={
                "family": "flooring",
                "code": "SPC-1",
                "names": {"zh": "a", "en": "b", "ms": "c"},
                "uom": "box",
            },
            headers=auth(token),
        )
        assert r.status_code == 403, r.text

    def test_parttime_cannot_receive_stock(self, client: TestClient) -> None:
        admin_token = sign_in(client, "admin")
        material = make_material(client, admin_token)

        token = sign_in(client, "parttime")
        r = client.post(
            "/api/stock/receive",
            json={"material_id": material["id"], "lot_ref": "DYE-1", "qty": "10"},
            headers=auth(token),
        )
        assert r.status_code == 403, r.text

    def test_staff_cannot_approve_an_allocation(self, client: TestClient) -> None:
        admin_token = sign_in(client, "admin")
        material = make_material(client, admin_token)
        client.post(
            "/api/stock/receive",
            json={"material_id": material["id"], "lot_ref": "DYE-1", "qty": "10"},
            headers=auth(admin_token),
        )
        allocation = client.post(
            "/api/allocations",
            json={
                "order_line_id": LINE_ID,
                "order_id": ORDER_ID,
                "material_id": material["id"],
                "lot_id": client.get(
                    "/api/stock/lots",
                    params={"material_id": material["id"]},
                    headers=auth(admin_token),
                ).json()["lots"][0]["id"],
                "qty": "5",
            },
            headers=auth(admin_token),
        ).json()

        token = sign_in(client, "staff")
        r = client.post(
            f"/api/allocations/{allocation['id']}/approve",
            json={},
            headers=auth(token),
        )
        assert r.status_code == 403, r.text

    def test_without_a_session_it_is_401(self, client: TestClient) -> None:
        r = client.get("/api/materials")
        assert r.status_code == 401, r.text


class TestMaterialsApi:
    def test_created_and_listed(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token, code="SPC-ABC")

        r = client.get("/api/materials", headers=auth(token))
        assert r.status_code == 200, r.text
        assert [m["code"] for m in r.json()["materials"]] == ["SPC-ABC"]
        assert material["is_active"] is True

    def test_a_duplicate_code_is_409_not_500(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        make_material(client, token, code="SPC-DUP")
        r = client.post(
            "/api/materials",
            json={
                "family": "flooring",
                "code": "SPC-DUP",
                "names": {"zh": "a", "en": "b", "ms": "c"},
                "uom": "box",
            },
            headers=auth(token),
        )
        assert r.status_code == 409, r.text

    def test_deactivating_removes_it_from_the_default_list(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)

        r = client.post(
            f"/api/materials/{material['id']}/deactivate", headers=auth(token)
        )
        assert r.status_code == 200, r.text
        assert r.json()["is_active"] is False

        listed = client.get("/api/materials", headers=auth(token)).json()["materials"]
        assert listed == []

    def test_an_unknown_material_is_404_not_500(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            f"/api/materials/{uuid.uuid4()}/deactivate", headers=auth(token)
        )
        assert r.status_code == 404, r.text


class TestStockApi:
    def test_receiving_creates_a_lot_and_a_movement(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)

        r = client.post(
            "/api/stock/receive",
            json={
                "material_id": material["id"],
                "lot_ref": "DYE-1",
                "qty": "20",
                "cost_sen": 1200,
            },
            headers=auth(token),
        )
        assert r.status_code == 200, r.text
        assert r.json()["qty_on_hand"] == "20"

        lots = client.get(
            "/api/stock/lots",
            params={"material_id": material["id"]},
            headers=auth(token),
        ).json()["lots"]
        assert len(lots) == 1

    def test_a_negative_resulting_quantity_is_422_not_500(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)
        lot = client.post(
            "/api/stock/receive",
            json={"material_id": material["id"], "lot_ref": "DYE-1", "qty": "5"},
            headers=auth(token),
        ).json()

        r = client.post(
            "/api/stock/adjust",
            json={"lot_id": lot["id"], "delta": "-100", "reason": "damage"},
            headers=auth(token),
        )
        assert r.status_code == 422, r.text

    def test_allocation_is_not_an_adjustable_reason(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)
        lot = client.post(
            "/api/stock/receive",
            json={"material_id": material["id"], "lot_ref": "DYE-1", "qty": "5"},
            headers=auth(token),
        ).json()

        r = client.post(
            "/api/stock/adjust",
            json={"lot_id": lot["id"], "delta": "-1", "reason": "allocation"},
            headers=auth(token),
        )
        assert r.status_code == 422, r.text


class TestAllocationsApi:
    def _lot(self, client: TestClient, token: str, material_id: str) -> dict:
        client.post(
            "/api/stock/receive",
            json={"material_id": material_id, "lot_ref": "DYE-1", "qty": "20"},
            headers=auth(token),
        )
        return client.get(
            "/api/stock/lots",
            params={"material_id": material_id},
            headers=auth(token),
        ).json()["lots"][0]

    def test_manual_allocation_creates_it_already_approved(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)
        lot = self._lot(client, token, material["id"])

        r = client.post(
            "/api/allocations",
            json={
                "order_line_id": LINE_ID,
                "order_id": ORDER_ID,
                "material_id": material["id"],
                "lot_id": lot["id"],
                "qty": "6",
            },
            headers=auth(token),
        )
        assert r.status_code == 201, r.text
        body = r.json()
        assert body["status"] == "approved"

        lots = client.get(
            "/api/stock/lots",
            params={"material_id": material["id"]},
            headers=auth(token),
        ).json()["lots"]
        assert lots[0]["qty_on_hand"] == "14"

    def test_manual_allocation_against_an_unknown_order_line_is_404(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)
        lot = self._lot(client, token, material["id"])

        r = client.post(
            "/api/allocations",
            json={
                "order_line_id": "not-a-real-line",
                "order_id": ORDER_ID,
                "material_id": material["id"],
                "lot_id": lot["id"],
                "qty": "6",
            },
            headers=auth(token),
        )
        assert r.status_code == 404, r.text

    def test_manual_allocation_against_the_wrong_order_is_404(
        self, client: TestClient
    ) -> None:
        # LINE_ID really belongs to ORDER_ID (see the fixture above). Nothing
        # checked that a caller's `order_id` actually named the line's own
        # order, so a mismatched id was stored on the allocation as if it
        # were true -- corrupting the one field a release or a report would
        # trust to say which order the stock went to.
        token = sign_in(client, "admin")
        material = make_material(client, token)
        lot = self._lot(client, token, material["id"])

        r = client.post(
            "/api/allocations",
            json={
                "order_line_id": LINE_ID,
                "order_id": str(uuid.uuid4()),
                "material_id": material["id"],
                "lot_id": lot["id"],
                "qty": "6",
            },
            headers=auth(token),
        )
        assert r.status_code == 404, r.text

        # And nothing was allocated: the stock is untouched.
        lots = client.get(
            "/api/stock/lots",
            params={"material_id": material["id"]},
            headers=auth(token),
        ).json()["lots"]
        assert lots[0]["qty_on_hand"] == "20"

    def test_approve_then_release_round_trips_the_stock(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token)
        lot = self._lot(client, token, material["id"])

        allocation = client.post(
            "/api/allocations",
            json={
                "order_line_id": LINE_ID,
                "order_id": ORDER_ID,
                "material_id": material["id"],
                "lot_id": lot["id"],
                "qty": "6",
            },
            headers=auth(token),
        ).json()

        r = client.post(
            f"/api/allocations/{allocation['id']}/release",
            json={"note": "order cancelled"},
            headers=auth(token),
        )
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "released"

        lots = client.get(
            "/api/stock/lots",
            params={"material_id": material["id"]},
            headers=auth(token),
        ).json()["lots"]
        assert lots[0]["qty_on_hand"] == "20"

    def test_rejecting_without_a_reason_is_422(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token, coverage_per_unit="18")
        self._lot(client, token, material["id"])

        proposed = client.get(
            "/api/allocations", params={"status": "proposed"}, headers=auth(token)
        ).json()["allocations"]
        # Nothing proposed itself here (no measurement push in this test) --
        # exercise the validation directly against a made-up id instead,
        # which the schema itself must refuse before any lookup happens.
        allocation_id = proposed[0]["id"] if proposed else str(uuid.uuid4())

        r = client.post(
            f"/api/allocations/{allocation_id}/reject",
            json={"reason": ""},
            headers=auth(token),
        )
        assert r.status_code == 422, r.text

    def test_an_unknown_allocation_is_404_not_500(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            f"/api/allocations/{uuid.uuid4()}/approve", json={}, headers=auth(token)
        )
        assert r.status_code == 404, r.text


class TestReorderAlertsApi:
    def test_alerts_reflect_available_not_raw_on_hand(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        material = make_material(client, token, reorder_level="10")
        client.post(
            "/api/stock/receive",
            json={"material_id": material["id"], "lot_ref": "DYE-1", "qty": "12"},
            headers=auth(token),
        )

        r = client.get("/api/inventory/alerts", headers=auth(token))
        assert r.status_code == 200, r.text
        assert r.json()["alerts"] == []

        lot = client.get(
            "/api/stock/lots",
            params={"material_id": material["id"]},
            headers=auth(token),
        ).json()["lots"][0]
        client.post(
            "/api/allocations",
            json={
                "order_line_id": LINE_ID,
                "order_id": ORDER_ID,
                "material_id": material["id"],
                "lot_id": lot["id"],
                "qty": "5",
            },
            headers=auth(token),
        )

        r = client.get("/api/inventory/alerts", headers=auth(token))
        # An approved allocation already left on_hand (12 - 5 = 7), still
        # below the reorder level of 10.
        alerts = r.json()["alerts"]
        assert len(alerts) == 1
        assert alerts[0]["available"] == "7"

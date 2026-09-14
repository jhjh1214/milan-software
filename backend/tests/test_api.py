"""The HTTP surface. §9.1, §9.2 and the authorisation rules, over the wire.

The routes are thin, so these tests check the things only HTTP can get wrong:
status codes, the up-to-date short circuit, that a retry is a 200 rather than an
error the device would keep retrying forever, and — since Phase 3 makes prices
server-owned — that nothing but an admin can move a price.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import db as db_module
from app.core.security import hash_pin
from app.main import app, get_session
from app.models.db import Base, Quote, RateCardVersion, User
from app.services.ingest import publish_card

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)
STANDARD = json.loads(
    (ROOT / "shared" / "rate-card-standard.json").read_text(encoding="utf-8")
)

PINS = {"admin": "1357", "staff": "2468", "parttime": "4821"}
PHONES = {"admin": "0110000001", "staff": "0110000002", "parttime": "0110000003"}


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
        c.sessions = factory  # type: ignore[attr-defined]
        yield c
    app.dependency_overrides.clear()
    db_module.configure(db_module.DATABASE_URL)


def sign_in(client: TestClient, role: str = "parttime") -> str:
    r = client.post(
        "/api/auth/login",
        json={
            "phone": PHONES[role],
            "pin": PINS[role],
            "device_id": str(uuid.uuid4()),
            "device_label": f"{role} handset",
        },
    )
    assert r.status_code == 200, r.text
    return r.json()["token"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


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


class TestSigningIn:
    def test_a_correct_pin_returns_a_token_and_the_role(
        self, client: TestClient
    ) -> None:
        r = client.post(
            "/api/auth/login",
            json={
                "phone": PHONES["staff"],
                "pin": PINS["staff"],
                "device_id": str(uuid.uuid4()),
            },
        )
        assert r.status_code == 200
        assert r.json()["token"]
        assert r.json()["user"]["role"] == "staff"

    def test_a_wrong_pin_is_401(self, client: TestClient) -> None:
        r = client.post(
            "/api/auth/login",
            json={
                "phone": PHONES["staff"],
                "pin": "9999",
                "device_id": str(uuid.uuid4()),
            },
        )
        assert r.status_code == 401

    def test_an_unknown_phone_answers_identically(self, client: TestClient) -> None:
        # Same status and same body as a wrong PIN. Anything else is a way to
        # enumerate which numbers belong to staff.
        wrong_pin = client.post(
            "/api/auth/login",
            json={
                "phone": PHONES["staff"],
                "pin": "9999",
                "device_id": str(uuid.uuid4()),
            },
        )
        unknown = client.post(
            "/api/auth/login",
            json={
                "phone": "0100000000",
                "pin": "9999",
                "device_id": str(uuid.uuid4()),
            },
        )
        assert unknown.status_code == wrong_pin.status_code
        assert unknown.json() == wrong_pin.json()

    def test_me_names_the_signed_in_user(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.get("/api/auth/me", headers=auth(token))
        assert r.status_code == 200
        assert r.json()["role"] == "admin"

    def test_picking_a_language_follows_the_account_not_the_session(
        self, client: TestClient
    ) -> None:
        # The point of this endpoint: it is the ACCOUNT that remembers, not
        # this one token. A second, independent sign-in sees the same pick.
        token = sign_in(client, "admin")
        r = client.post(
            "/api/auth/language", json={"language": "en"}, headers=auth(token)
        )
        assert r.status_code == 200
        assert r.json()["language"] == "en"

        second_token = sign_in(client, "admin")
        again = client.get("/api/auth/me", headers=auth(second_token))
        assert again.json()["language"] == "en"

    def test_an_unrecognised_language_is_rejected(self, client: TestClient) -> None:
        token = sign_in(client, "admin")
        r = client.post(
            "/api/auth/language", json={"language": "fr"}, headers=auth(token)
        )
        assert r.status_code == 422

    def test_signing_out_ends_the_session(self, client: TestClient) -> None:
        token = sign_in(client)
        assert client.post("/api/auth/logout", headers=auth(token)).status_code == 204
        assert client.get("/api/auth/me", headers=auth(token)).status_code == 401


class TestRateLimiting:
    """`app.core.rate_limit`'s own tests cover the sliding-window arithmetic
    directly; these just confirm the middleware is actually wired in.

    A different phone number every request, all wrong, so this exercises the
    IP throttle alone -- app.services.auth's own per-*phone* backoff (already
    covered in test_auth.py) would otherwise trip first and this would be
    testing the wrong mechanism.
    """

    def test_a_burst_from_one_source_eventually_gets_429(
        self, client: TestClient
    ) -> None:
        from app.main import _LOGIN_RULE  # the current production limit

        responses = [
            client.post(
                "/api/auth/login",
                json={
                    "phone": f"019{i:07d}",
                    "pin": "0000",
                    "device_id": "d1",
                },
            )
            for i in range(_LOGIN_RULE.limit + 1)
        ]
        assert [r.status_code for r in responses[:-1]] == [401] * _LOGIN_RULE.limit
        blocked = responses[-1]
        assert blocked.status_code == 429
        assert int(blocked.headers["Retry-After"]) > 0

    def test_health_is_never_rate_limited(self, client: TestClient) -> None:
        from app.main import _GLOBAL_RULE

        for _ in range(_GLOBAL_RULE.limit + 20):
            assert client.get("/api/health").status_code == 200


class TestEverythingNeedsASession:
    @pytest.mark.parametrize(
        ("method", "path"),
        [
            ("get", "/api/bundle"),
            ("get", "/api/auth/me"),
            ("post", "/api/quotes"),
            ("post", "/api/rate-cards"),
        ],
    )
    def test_no_token_is_401(self, client: TestClient, method: str, path: str) -> None:
        # A body is sent even on the GETs so that a route which validated the
        # body before checking the session would still be caught here.
        r = client.request(method.upper(), path, json={})
        assert r.status_code == 401
        assert r.headers.get("WWW-Authenticate") == "Bearer"

    def test_a_made_up_token_is_401(self, client: TestClient) -> None:
        assert client.get("/api/bundle", headers=auth("nonsense")).status_code == 401

    def test_a_token_without_the_bearer_scheme_is_401(self, client: TestClient) -> None:
        token = sign_in(client)
        r = client.get("/api/bundle", headers={"Authorization": token})
        assert r.status_code == 401

    def test_health_needs_nothing(self, client: TestClient) -> None:
        # The container health check and Caddy call it, and it says nothing
        # about the data.
        assert client.get("/api/health").json() == {"status": "ok"}


class TestBundle:
    def test_it_serves_the_active_fair_card(self, client: TestClient) -> None:
        r = client.get(
            "/api/bundle", params={"list_id": "fair"}, headers=auth(sign_in(client))
        )
        assert r.status_code == 200
        body = r.json()
        assert body["rate_card_version"] == 1
        assert body["up_to_date"] is False
        # 77 printed rows plus the 4 stair and landing placeholders, which the
        # bundle carries so a handset knows the products exist — the engine is
        # what refuses to price them.
        assert len(body["payload"]["rules"]) == 81

    def test_it_serves_the_standard_card_separately(self, client: TestClient) -> None:
        r = client.get(
            "/api/bundle",
            params={"list_id": "standard"},
            headers=auth(sign_in(client)),
        )
        assert r.json()["rate_card_version"] == 101

    def test_a_current_device_gets_no_payload(self, client: TestClient) -> None:
        # §9.1. A fair's connection should not be spent re-downloading a card
        # the phone already has.
        r = client.get(
            "/api/bundle",
            params={"list_id": "fair", "since_version": 1},
            headers=auth(sign_in(client)),
        )
        body = r.json()
        assert body["up_to_date"] is True
        assert body["payload"] is None

    def test_a_stale_device_gets_the_whole_card(self, client: TestClient) -> None:
        # Replaced wholesale, never diffed.
        r = client.get(
            "/api/bundle",
            params={"list_id": "fair", "since_version": 0},
            headers=auth(sign_in(client)),
        )
        body = r.json()
        assert body["up_to_date"] is False
        assert body["payload"] is not None

    def test_a_parttimer_may_still_pull_the_card(self, client: TestClient) -> None:
        # Rule 8 — "part-timers never see a rate" — is about what the screen
        # shows. The device still needs the card to price a line, and blocking
        # it here would mean no quoting at a fair.
        r = client.get("/api/bundle", headers=auth(sign_in(client, "parttime")))
        assert r.status_code == 200

    def test_an_unknown_list_is_rejected_by_validation(
        self, client: TestClient
    ) -> None:
        r = client.get(
            "/api/bundle", params={"list_id": "nope"}, headers=auth(sign_in(client))
        )
        assert r.status_code == 422


class TestPublishing:
    def bumped(self, version: int = 2) -> dict:
        return {"list_id": "fair", "payload": {**FAIR, "version": version}}

    def test_an_admin_can_publish(self, client: TestClient) -> None:
        r = client.post(
            "/api/rate-cards",
            json=self.bumped(),
            headers=auth(sign_in(client, "admin")),
        )
        assert r.status_code == 200
        assert r.json()["version"] == 2

    def test_staff_cannot_publish(self, client: TestClient) -> None:
        # §3: staff see rates and cannot edit them.
        r = client.post(
            "/api/rate-cards",
            json=self.bumped(),
            headers=auth(sign_in(client, "staff")),
        )
        assert r.status_code == 403

    def test_a_parttimer_cannot_publish(self, client: TestClient) -> None:
        r = client.post(
            "/api/rate-cards",
            json=self.bumped(),
            headers=auth(sign_in(client, "parttime")),
        )
        assert r.status_code == 403

    def test_a_refused_publish_changes_nothing(self, client: TestClient) -> None:
        client.post(
            "/api/rate-cards",
            json=self.bumped(),
            headers=auth(sign_in(client, "staff")),
        )
        still = client.get("/api/bundle", headers=auth(sign_in(client)))
        assert still.json()["rate_card_version"] == 1

    def test_every_device_sees_the_new_card_on_its_next_pull(
        self, client: TestClient
    ) -> None:
        # The Phase 3 acceptance criterion: publish a rate change, every device
        # picks it up on next connect.
        handset = sign_in(client, "parttime")
        before = client.get(
            "/api/bundle", params={"since_version": 1}, headers=auth(handset)
        )
        assert before.json()["up_to_date"] is True

        client.post(
            "/api/rate-cards",
            json=self.bumped(),
            headers=auth(sign_in(client, "admin")),
        )

        after = client.get(
            "/api/bundle", params={"since_version": 1}, headers=auth(handset)
        )
        assert after.json()["up_to_date"] is False
        assert after.json()["rate_card_version"] == 2
        assert after.json()["payload"] is not None

    def test_a_version_that_is_not_newer_is_refused(self, client: TestClient) -> None:
        # Two different cards answering to one version means a quote recording
        # that version could mean either of them.
        r = client.post(
            "/api/rate-cards",
            json=self.bumped(version=1),
            headers=auth(sign_in(client, "admin")),
        )
        assert r.status_code == 409

    def test_a_card_with_no_version_is_refused(self, client: TestClient) -> None:
        payload = {k: v for k, v in FAIR.items() if k != "version"}
        r = client.post(
            "/api/rate-cards",
            json={"list_id": "fair", "payload": payload},
            headers=auth(sign_in(client, "admin")),
        )
        assert r.status_code == 422

    def test_the_publisher_is_recorded(self, client: TestClient) -> None:
        r = client.post(
            "/api/rate-cards",
            json=self.bumped(),
            headers=auth(sign_in(client, "admin")),
        )
        assert r.json()["published_by"] is not None


class TestLiveProductPriceEdit:
    """A staff or admin member changing one product's price directly, live
    immediately -- no whole-card upload, no preview ceremony."""

    def _edit(
        self,
        client: TestClient,
        token: str,
        *,
        rule_id: str = "night-curtain-lo",
        **over,
    ):
        # night-curtain-lo's real mvp_rate_sen is 4000 -- sent unchanged by
        # default, the same way a real edit form would always submit both
        # fields it displays, whether or not each one moved.
        body = {
            "rate_sen": 4000,
            "mvp_rate_sen": 4000,
            "reason": "matched a competitor at the fair",
        }
        body.update(over)
        return client.post(
            f"/api/rate-cards/fair/products/{rule_id}/price",
            json=body,
            headers=auth(token),
        )

    def test_staff_can_edit_a_price(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["rate_sen"] == 4000
        # shared/rate-card-standard.json is already published at version
        # 101 in this fixture's own setup, and `rate_cards.version` is one
        # global sequence across both lists -- so the first edit to fair
        # (still at 1) has to jump past it, not merely to 2.
        assert body["version"] == 102

    def test_admin_can_edit_a_price(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "admin"))
        assert r.status_code == 200, r.text

    def test_a_parttimer_cannot_edit_a_price(self, client: TestClient) -> None:
        # Hard rule 8: a part-timer never sees a rate at all, let alone
        # changes one.
        r = self._edit(client, sign_in(client, "parttime"))
        assert r.status_code == 403

    def test_it_is_live_on_the_very_next_pull(self, client: TestClient) -> None:
        handset = sign_in(client, "parttime")
        self._edit(client, sign_in(client, "staff"))

        bundle = client.get(
            "/api/bundle", params={"list_id": "fair"}, headers=auth(handset)
        )
        assert bundle.json()["rate_card_version"] == 102
        rule = next(
            r
            for r in bundle.json()["payload"]["rules"]
            if r["id"] == "night-curtain-lo"
        )
        assert rule["rate_sen"] == 4000

    def test_the_old_version_stays_explainable(self, client: TestClient) -> None:
        # A quote already priced at version 1 must not have its own rate
        # change under it. The active card is now version 2; version 1 is
        # superseded but still stored -- checked via a direct session read
        # since there is no route that serves a non-active version (nothing
        # needs one).
        self._edit(client, sign_in(client, "staff"))
        with client.sessions() as session:
            v1 = session.get(RateCardVersion, 1)
            assert v1 is not None
            v1_rule = next(
                r for r in v1.payload["rules"] if r["id"] == "night-curtain-lo"
            )
            assert v1_rule["rate_sen"] == 4600, "the superseded row is untouched"

    def test_a_provisional_row_clears_its_flag_when_given_a_real_rate(
        self, client: TestClient
    ) -> None:
        # A22: supplying a real price on a placeholder clears the flag in
        # the same edit -- a flag and a number that could drift apart is
        # exactly the bug that rule exists to prevent.
        r = self._edit(
            client,
            sign_in(client, "admin"),
            rule_id="stair-step-narrow",
            rate_sen=12000,
            mvp_rate_sen=None,
        )
        assert r.status_code == 200, r.text
        products = client.get(
            "/api/rate-cards/fair/products", headers=auth(sign_in(client, "staff"))
        ).json()["products"]
        row = next(p for p in products if p["id"] == "stair-step-narrow")
        assert row["provisional"] is False
        assert row["rate_sen"] == 12000

    def test_no_such_product_is_404(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"), rule_id="not-a-real-product")
        assert r.status_code == 404

    def test_a_missing_reason_is_422(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"), reason="")
        assert r.status_code == 422

    def test_a_short_reason_is_422(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"), reason="hi")
        assert r.status_code == 422

    def test_a_zero_rate_is_422(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"), rate_sen=0)
        assert r.status_code == 422

    def test_a_negative_rate_is_422(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"), rate_sen=-100)
        assert r.status_code == 422

    def test_no_change_is_422(self, client: TestClient) -> None:
        r = self._edit(client, sign_in(client, "staff"), rate_sen=4600)
        assert r.status_code == 422

    def test_the_products_list_needs_staff_or_admin_too(
        self, client: TestClient
    ) -> None:
        r = client.get(
            "/api/rate-cards/fair/products",
            headers=auth(sign_in(client, "parttime")),
        )
        assert r.status_code == 403

    def test_the_products_list_reflects_the_active_card(
        self, client: TestClient
    ) -> None:
        r = client.get(
            "/api/rate-cards/fair/products", headers=auth(sign_in(client, "staff"))
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["version"] == 1
        row = next(p for p in body["products"] if p["id"] == "night-curtain-lo")
        assert row["rate_sen"] == 4600


class TestPush:
    def test_a_quote_is_accepted_and_repriced(self, client: TestClient) -> None:
        r = client.post("/api/quotes", json=a_quote(), headers=auth(sign_in(client)))
        assert r.status_code == 200
        body = r.json()
        assert body["duplicate"] is False
        assert body["server_total_sen"] == 55200
        assert body["discrepancies"] == []

    def test_a_retry_is_a_success_not_an_error(self, client: TestClient) -> None:
        # §9.2. Treating a retry as a failure would have the outbox retry
        # forever, and the row would never drain.
        token = auth(sign_in(client))
        payload = a_quote()
        first = client.post("/api/quotes", json=payload, headers=token)
        second = client.post("/api/quotes", json=payload, headers=token)

        assert first.status_code == 200
        assert second.status_code == 200
        assert first.json()["duplicate"] is False
        assert second.json()["duplicate"] is True
        assert second.json()["server_total_sen"] == first.json()["server_total_sen"]

    def test_a_disagreement_still_returns_200(self, client: TestClient) -> None:
        # §9.4: accept the order, log the discrepancy. A 4xx here would lose a
        # sale the customer has already put a deposit on.
        r = client.post(
            "/api/quotes", json=a_quote(total=55100), headers=auth(sign_in(client))
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["discrepancies"]) == 1
        assert body["discrepancies"][0]["server_total_sen"] == 55200
        assert body["discrepancies"][0]["device_total_sen"] == 55100

    def test_the_quote_records_who_took_it(self, client: TestClient) -> None:
        # From the session, never from the body: a handset must not be able to
        # claim the sale was someone else's.
        token = sign_in(client, "staff")
        payload = a_quote()
        client.post("/api/quotes", json=payload, headers=auth(token))

        with client.sessions() as s:  # type: ignore[attr-defined]
            quote = s.get(Quote, payload["id"])
            staff = s.scalars(select(User).where(User.phone == PHONES["staff"])).one()
            assert quote.taken_by_user_id == staff.id

    def test_an_unknown_rate_card_version_is_a_conflict(
        self, client: TestClient
    ) -> None:
        payload = a_quote()
        payload["rate_card_version"] = 999
        r = client.post("/api/quotes", json=payload, headers=auth(sign_in(client)))
        assert r.status_code == 409

    def test_a_malformed_push_is_rejected_at_the_door(self, client: TestClient) -> None:
        payload = a_quote()
        del payload["lines"][0]["room"]
        r = client.post("/api/quotes", json=payload, headers=auth(sign_in(client)))
        assert r.status_code == 422

    def test_a_negative_dimension_is_rejected(self, client: TestClient) -> None:
        payload = a_quote()
        payload["lines"][0]["width_tmm"] = -1
        r = client.post("/api/quotes", json=payload, headers=auth(sign_in(client)))
        assert r.status_code == 422

    def test_missing_width_is_not_malformed_it_is_a_room_sourced_line(
        self, client: TestClient
    ) -> None:
        """`width_tmm` widened to nullable for exactly one case: a
        room-sourced flooring line prices from `direct_area_sqft` instead.
        Missing at the schema level is no longer malformed on its own."""
        payload = a_quote()
        del payload["lines"][0]["width_tmm"]
        payload["lines"][0]["direct_area_sqft"] = "250"
        payload["lines"][0]["variant"] = "spc_4mm_1mm"
        payload["lines"][0]["height_tmm"] = None
        payload["lines"][0]["device_total_sen"] = None
        payload["device_total_sen"] = None
        r = client.post("/api/quotes", json=payload, headers=auth(sign_in(client)))
        assert r.status_code == 200, r.text

    def test_neither_width_nor_a_direct_area_is_not_silently_priced(
        self, client: TestClient
    ) -> None:
        """A line the server genuinely cannot price -- neither dimensions
        nor a pre-known area -- still lands (the money is not in question
        here), but is not silently charged nothing. Same rule as any other
        unpriceable line (hard rule: never guess a price)."""
        payload = a_quote()
        del payload["lines"][0]["width_tmm"]
        payload["lines"][0]["height_tmm"] = None
        payload["lines"][0]["device_total_sen"] = None
        payload["device_total_sen"] = None
        r = client.post("/api/quotes", json=payload, headers=auth(sign_in(client)))
        assert r.status_code == 200, r.text
        assert r.json()["server_total_sen"] == 0


class TestBuyerDetailsOverTheWire:
    """SPEC.md §10.3, Phase 7. The merge and the staleness rule are tested
    against the service in `test_buyer_details_push.py`; what is checked here
    is the route -- that it exists, that it needs a session, and that a device
    can drive it with the body the app actually builds."""

    def _an_order(self, client: TestClient) -> str:
        order_id = str(uuid.uuid4())
        payload = {
            "id": order_id,
            "quote_id": str(uuid.uuid4()),
            "channel": "fair",
            "pinned_rate_card_version": 1,
            "customer_name": "Ah Lian",
            "estimate_total_sen": 1_200_000,
            "deposit_paid_sen": 30000,
            "confirmed_at": datetime.now(UTC).isoformat(),
            "lines": [
                {
                    "id": str(uuid.uuid4()),
                    "quote_line_id": str(uuid.uuid4()),
                    "sort_order": 0,
                    "room": "Living room",
                    "variant": "night_curtain",
                    "layer": "night",
                    "est_width_tmm": 36576,
                    "applied_rule_id": "night-curtain-lo",
                    "applied_rate_card_version": 1,
                    "standard_rate_sen": 4600,
                    "rate_sen": 4600,
                    "billed_qty": "12",
                    "billed_unit": "ft",
                    "line_total_sen": 1_200_000,
                }
            ],
        }
        token = sign_in(client, "staff")
        r = client.post("/api/orders", json=payload, headers=auth(token))
        assert r.status_code == 200, r.text
        return order_id

    def test_a_handset_can_push_what_it_captured(self, client: TestClient) -> None:
        order_id = self._an_order(client)
        token = sign_in(client, "staff")

        r = client.post(
            "/api/orders/buyer",
            json={
                "order_id": order_id,
                "captured_at": datetime.now(UTC).isoformat(),
                "tin": "C1234567890",
                "address_line1": "12 Jalan Melaka",
                "city": "Melaka",
                "state": "Melaka",
                "postcode": "75000",
            },
            headers=auth(token),
        )

        assert r.status_code == 200, r.text
        body = r.json()
        assert body["complete"] is True
        assert body["missing"] == []
        assert body["refused_because"] is None

    def test_what_is_outstanding_comes_back_to_the_handset(
        self, client: TestClient
    ) -> None:
        # So the app can say what still has to be collected without asking a
        # second question, and without computing a second answer of its own.
        order_id = self._an_order(client)
        token = sign_in(client, "staff")

        body = client.post(
            "/api/orders/buyer",
            json={
                "order_id": order_id,
                "captured_at": datetime.now(UTC).isoformat(),
                "tin": "C1234567890",
            },
            headers=auth(token),
        ).json()

        assert body["complete"] is False
        assert body["missing"] == ["address"]

    def test_it_needs_a_session(self, client: TestClient) -> None:
        # An IC number and a home address are the most sensitive thing this
        # system holds, and the route that writes them is not an exception to
        # §12's rule that everything but health and sign-in is authenticated.
        r = client.post(
            "/api/orders/buyer",
            json={
                "order_id": str(uuid.uuid4()),
                "captured_at": datetime.now(UTC).isoformat(),
            },
        )
        assert r.status_code == 401


class TestTheMeasurementQueue:
    """SPEC.md §11 Phase 5. Over the wire, which is the only place the clock
    and the authorisation are decided -- the grouping itself is tested against
    the service in `test_measurement_queue.py`."""

    def _an_order(self, client: TestClient, **over) -> str:
        order_id = str(uuid.uuid4())
        payload = {
            "id": order_id,
            "quote_id": str(uuid.uuid4()),
            "channel": "fair",
            "pinned_rate_card_version": 1,
            "estimate_total_sen": 55200,
            "deposit_paid_sen": 30000,
            "confirmed_at": datetime.now(UTC).isoformat(),
            "lines": [
                {
                    "id": str(uuid.uuid4()),
                    "quote_line_id": str(uuid.uuid4()),
                    "sort_order": 0,
                    "room": "Living room",
                    "variant": "night_curtain",
                    "layer": "night",
                    "est_width_tmm": 36576,
                    "applied_rule_id": "rule-1",
                    "applied_rate_card_version": 1,
                    "standard_rate_sen": 4600,
                    "rate_sen": 4600,
                    "billed_qty": "12",
                    "billed_unit": "ft",
                    "line_total_sen": 55200,
                }
            ],
        }
        payload.update(over)
        token = sign_in(client, "staff")
        r = client.post("/api/orders", json=payload, headers=auth(token))
        assert r.status_code == 200, r.text
        return order_id

    def test_a_confirmed_order_appears_grouped(self, client: TestClient) -> None:
        self._an_order(client, customer_phone="012-345 6789", customer_name="Ah Lian")
        self._an_order(client, customer_phone="+60123456789", customer_name="Ah Lian")

        token = sign_in(client, "staff")
        r = client.get("/api/measurement-queue", headers=auth(token))

        assert r.status_code == 200, r.text
        body = r.json()
        assert body["total_orders"] == 2
        (group,) = body["groups"]
        assert group["key"] == "phone:0123456789"
        assert len(group["jobs"]) == 2

    def test_the_clock_is_the_server_s(self, client: TestClient) -> None:
        # An order confirmed a moment ago has waited no days. The route reads
        # the clock once and passes it down, so nothing on the screen can
        # disagree with anything else on it about what today is.
        self._an_order(client)

        token = sign_in(client, "staff")
        body = client.get("/api/measurement-queue", headers=auth(token)).json()

        assert body["groups"][0]["jobs"][0]["waiting_days"] == 0

    def test_it_needs_a_session(self, client: TestClient) -> None:
        r = client.get("/api/measurement-queue")
        assert r.status_code == 401
        assert r.headers["WWW-Authenticate"] == "Bearer"


class TestTheReports:
    """SPEC.md §11 Phase 5. Who may read them, which is the part only HTTP
    decides -- the arithmetic is tested against the services."""

    ROUTES = (
        "/api/reports/variance",
        "/api/reports/fairs",
        "/api/reports/balances",
    )

    @pytest.mark.parametrize("route", ROUTES)
    def test_an_admin_can_read_them(self, client: TestClient, route: str) -> None:
        token = sign_in(client, "admin")
        assert client.get(route, headers=auth(token)).status_code == 200

    @pytest.mark.parametrize("route", ROUTES)
    @pytest.mark.parametrize("role", ["staff", "parttime"])
    def test_nobody_else_can(self, client: TestClient, route: str, role: str) -> None:
        # The variance report names people and ranks them; the other two carry
        # margin-shaped numbers. §3: part-timers never see a rate, cost or
        # margin, and a report is the easiest place to leak one.
        token = sign_in(client, role)
        assert client.get(route, headers=auth(token)).status_code == 403

    @pytest.mark.parametrize("route", ROUTES)
    def test_they_need_a_session(self, client: TestClient, route: str) -> None:
        assert client.get(route).status_code == 401

    def test_the_variance_report_says_when_nothing_is_priced(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        body = client.get("/api/reports/variance", headers=auth(token)).json()

        assert body["nothing_priced_yet"] is True

    def test_the_balances_report_ages_against_the_server_clock(
        self, client: TestClient
    ) -> None:
        token = sign_in(client, "admin")
        body = client.get("/api/reports/balances", headers=auth(token)).json()

        # Four buckets whatever the data, so a quiet month is not a differently
        # shaped report from a busy one.
        #
        # Ranges, not labels. The words are the reader's client's business:
        # the dashboard speaks three languages (SPEC.md 13 C9) and an English
        # label here would have been the one English string on a Malay screen.
        assert [(b["days_from"], b["days_to"]) for b in body["buckets"]] == [
            (0, 31),
            (31, 61),
            (61, 91),
            (91, None),
        ]


def test_health(client: TestClient) -> None:
    assert client.get("/api/health").json() == {"status": "ok"}

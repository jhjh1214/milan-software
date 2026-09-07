"""Buyer details reaching the server. SPEC.md §10.3, §11 Phase 7.

The details an e-invoice needs are captured on the handset while the customer is
standing there. Until migration 0006 they stayed there — and the **office** runs
the SQL Account export, so details that never leave a phone are the same as no
details as far as the accounts system is concerned. That is precisely the
failure the rate locks had before 0005: correct machinery, stored somewhere
nothing else could read.

Two behaviours are what this module is really about, and both exist because
several handsets work one fair and any of them can capture for one order:

* it **merges** — a field the payload does not carry keeps what is stored, so
  the measurer's TIN and the office's address end up on one row;
* it **refuses a stale push** rather than letting the last arrival win.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import BuyerDetailsIn, OrderIn, OrderLineIn
from app.models.db import Base, Order
from app.services.ingest import push_buyer_details, push_order

CONFIRMED_AT = datetime(2026, 8, 29, 14, 0, tzinfo=UTC)
MEASURED_AT = CONFIRMED_AT + timedelta(days=14)

ORDER_ID = "11111111-1111-4111-8111-111111111111"
LINE_ID = "22222222-2222-4222-8222-222222222222"


@pytest.fixture
def db() -> Iterator[sessionmaker[Session]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False)
    engine.dispose()


def seed(session: Session, *, name: str | None = "Ah Lian") -> None:
    push_order(
        session,
        OrderIn(
            id=ORDER_ID,
            quote_id="33333333-3333-4333-8333-333333333333",
            channel="fair",
            pinned_rate_card_version=1,
            customer_name=name,
            estimate_total_sen=1_200_000,
            deposit_paid_sen=30000,
            confirmed_at=CONFIRMED_AT,
            lines=[
                OrderLineIn(
                    id=LINE_ID,
                    quote_line_id="44444444-4444-4444-8444-444444444444",
                    sort_order=0,
                    room="Living room",
                    variant="night_curtain",
                    layer="night",
                    est_width_tmm=36576,
                    est_height_tmm=27432,
                    applied_rule_id="night-curtain-lo",
                    applied_rate_card_version=1,
                    standard_rate_sen=4600,
                    rate_sen=4600,
                    billed_qty="12",
                    billed_unit="ft",
                    line_total_sen=1_200_000,
                )
            ],
        ),
    )
    session.commit()


def capture(session: Session, *, at: datetime | None = None, **fields):
    return push_buyer_details(
        session,
        BuyerDetailsIn(
            order_id=ORDER_ID,
            captured_at=at or MEASURED_AT,
            **fields,
        ),
    )


def stored(session: Session) -> Order:
    session.expire_all()
    return session.get(Order, ORDER_ID)


def test_details_captured_on_a_handset_reach_the_server(
    db: sessionmaker[Session],
) -> None:
    """The whole reason migration 0006 exists."""
    with db() as session:
        seed(session)
        result = capture(
            session,
            tin="C1234567890",
            address_line1="12 Jalan Melaka",
            city="Melaka",
            state="Melaka",
            postcode="75000",
        )
        session.commit()

        assert result.complete is True
        assert result.missing == []
        assert result.refused_because is None

        order = stored(session)
        assert order.buyer_tin == "C1234567890"
        assert order.buyer_city == "Melaka"
        assert order.buyer_captured_at is not None


def test_what_is_still_missing_comes_back_from_the_same_rule(
    db: sessionmaker[Session],
) -> None:
    """Not a second answer beside the device's.

    A server that computed completeness its own way would disagree with the
    handset the first time either changed, and the disagreement would surface
    as an order the office thinks is ready and the app will not move.
    """
    with db() as session:
        seed(session)
        result = capture(session, tin="C1234567890")
        session.commit()

        assert result.complete is False
        assert result.missing == ["address"], "name and identifier are in hand"


def test_a_name_the_order_already_had_counts(db: sessionmaker[Session]) -> None:
    with db() as session:
        seed(session)
        assert capture(session).missing == ["identifier", "address"]


def test_an_order_with_no_name_is_missing_one(db: sessionmaker[Session]) -> None:
    with db() as session:
        seed(session, name=None)
        assert capture(session).missing == ["name", "identifier", "address"]


class TestMerging:
    """Two people capture for one order and both answers survive."""

    def test_a_second_push_adds_without_blanking_the_first(
        self, db: sessionmaker[Session]
    ) -> None:
        # The measurer takes the TIN at the house; the office adds the address
        # from a scan of the IC the next morning. A payload that blanked what
        # it did not carry would lose whichever landed first, and both are
        # things somebody actually collected.
        with db() as session:
            seed(session)
            capture(session, tin="C1234567890")
            session.commit()

            result = capture(
                session,
                at=MEASURED_AT + timedelta(hours=1),
                address_line1="12 Jalan Melaka",
                city="Melaka",
                state="Melaka",
                postcode="75000",
            )
            session.commit()

            assert result.complete is True
            assert stored(session).buyer_tin == "C1234567890"

    def test_an_empty_string_clears_a_field(self, db: sessionmaker[Session]) -> None:
        # How a wrong IC number is removed. Absent means "leave it"; empty
        # means "there is nothing here", which is what a legal requirement
        # needs a blank to mean.
        with db() as session:
            seed(session)
            capture(session, id_type="nric", id_number="900101015555")
            session.commit()
            assert stored(session).buyer_id_type == "nric"

            capture(session, at=MEASURED_AT + timedelta(hours=1), id_type="")
            session.commit()
            assert stored(session).buyer_id_type is None

    def test_whitespace_is_stored_as_absent(self, db: sessionmaker[Session]) -> None:
        # A field holding a space must not satisfy a legal requirement, and the
        # trim happens here rather than being trusted to whatever called it.
        with db() as session:
            seed(session)
            result = capture(session, tin="   ", city="  Melaka  ")
            session.commit()

            assert stored(session).buyer_tin is None
            assert stored(session).buyer_city == "Melaka"
            assert "identifier" in result.missing

    def test_re_sending_the_same_payload_changes_nothing(
        self, db: sessionmaker[Session]
    ) -> None:
        # Safe to retry: the outbox will re-send after a dropped connection.
        with db() as session:
            seed(session)
            fields = {
                "tin": "C1234567890",
                "address_line1": "12 Jalan Melaka",
                "city": "Melaka",
                "state": "Melaka",
                "postcode": "75000",
            }
            first = capture(session, **fields)
            session.commit()
            second = capture(session, **fields)
            session.commit()

            assert first.complete == second.complete is True
            assert stored(session).buyer_tin == "C1234567890"


class TestStalePushes:
    """Several handsets, one order, and no ordering guarantee offline."""

    def test_an_older_capture_arriving_late_is_refused(
        self, db: sessionmaker[Session]
    ) -> None:
        # Phone 1 captures at 10am and loses signal. Phone 2 corrects the TIN
        # at 11am and syncs. Phone 1 reconnects at noon. Without this, the
        # correction is silently undone by a payload that is older than what it
        # overwrites.
        with db() as session:
            seed(session)
            capture(session, at=MEASURED_AT + timedelta(hours=1), tin="CORRECTED")
            session.commit()

            result = capture(session, at=MEASURED_AT, tin="WRONG")
            session.commit()

            assert result.refused_because == "stale"
            assert stored(session).buyer_tin == "CORRECTED"

    def test_a_refused_stale_push_still_reports_the_truth(
        self, db: sessionmaker[Session]
    ) -> None:
        # The handset that sent it needs to know where the order actually
        # stands, not just that it was ignored.
        with db() as session:
            seed(session)
            capture(
                session,
                at=MEASURED_AT + timedelta(hours=1),
                tin="C1234567890",
            )
            session.commit()

            result = capture(session, at=MEASURED_AT, tin="WRONG")
            assert result.refused_because == "stale"
            assert result.missing == ["address"], "what is really outstanding"

    def test_the_whole_push_is_refused_not_merged_field_by_field(
        self, db: sessionmaker[Session]
    ) -> None:
        # A half-applied older record is a buyer nobody can account for: some
        # fields from 10am, some from 11am, and no way to tell which.
        with db() as session:
            seed(session)
            capture(session, at=MEASURED_AT + timedelta(hours=1), tin="CORRECTED")
            session.commit()

            capture(session, at=MEASURED_AT, city="Melaka", postcode="75000")
            session.commit()

            order = stored(session)
            assert order.buyer_city is None
            assert order.buyer_postcode is None

    def test_the_same_instant_is_not_stale(self, db: sessionmaker[Session]) -> None:
        # A retry carries the same captured_at. Refusing it would make the
        # outbox's own retry look like a conflict.
        with db() as session:
            seed(session)
            capture(session, tin="C1234567890")
            session.commit()

            result = capture(session, city="Melaka")
            session.commit()

            assert result.refused_because is None
            assert stored(session).buyer_city == "Melaka"


def test_details_for_an_order_that_has_not_landed_are_refused(
    db: sessionmaker[Session],
) -> None:
    """The outbox is FIFO so it should not happen — but writing details onto
    nothing is worse than saying so."""
    with db() as session:
        result = push_buyer_details(
            session,
            BuyerDetailsIn(
                order_id=str(uuid.uuid4()),
                captured_at=MEASURED_AT,
                tin="C1234567890",
            ),
        )
        assert result.refused_because == "unknown_order"
        assert result.complete is False


def test_the_einvoice_request_is_carried(db: sessionmaker[Session]) -> None:
    """§10.3: asked for at any value, so it is a reason to capture on its own."""
    with db() as session:
        seed(session)
        capture(session, einvoice_requested=True)
        session.commit()
        assert stored(session).einvoice_requested is True

        # Absent leaves it, like every other field.
        capture(session, at=MEASURED_AT + timedelta(hours=1), tin="C1")
        session.commit()
        assert stored(session).einvoice_requested is True


def test_a_naive_stored_timestamp_does_not_raise(db: sessionmaker[Session]) -> None:
    """SQLite drops the timezone off a ``timestamptz``; Postgres does not.

    Comparing an aware payload against a naive stored value raises — and it
    would raise only under SQLite, so it would pass in CI and fail the first
    time somebody pushed a correction against real Postgres. Written as its own
    test because the comparison is the only place the difference shows.
    """
    with db() as session:
        seed(session)
        capture(session, tin="C1234567890")
        session.commit()

        order = stored(session)
        order.buyer_captured_at = MEASURED_AT.replace(tzinfo=None)
        session.commit()

        result = capture(session, at=MEASURED_AT + timedelta(hours=1), city="Melaka")
        assert result.refused_because is None

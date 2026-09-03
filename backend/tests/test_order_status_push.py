"""Walking an order along the pipeline on the server. SPEC.md §6.3 and §9.2.

The device has already made the move locally and is telling the server about it.
The server re-validates rather than trusting it, against the same module and the
same shared fixtures the device used — so a disagreement means the two have
genuinely drifted, not that one of them is guessing.

Idempotency hangs on the **event id**, not on the order: an order walks the
pipeline many times, so what must not be applied twice is one particular move,
and a retry has to be harmless without blocking the next legitimate step.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import OrderIn, OrderLineIn, StatusChangeIn
from app.models.db import Base, Order, OrderEvent, OrderLine, User
from app.services.ingest import advance_order_status, push_order

CONFIRMED_AT = datetime(2026, 8, 29, 14, 0, tzinfo=UTC)


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


ORDER_ID = "11111111-1111-4111-8111-111111111111"
LINE_ID = "22222222-2222-4222-8222-222222222222"


def seed(session: Session, *, material_key: str | None = None) -> None:
    push_order(
        session,
        OrderIn(
            id=ORDER_ID,
            quote_id="33333333-3333-4333-8333-333333333333",
            channel="fair",
            pinned_rate_card_version=1,
            estimate_total_sen=96000,
            deposit_paid_sen=30000,
            confirmed_at=CONFIRMED_AT,
            lines=[
                OrderLineIn(
                    id=LINE_ID,
                    quote_line_id="44444444-4444-4444-8444-444444444444",
                    sort_order=0,
                    room="Living room",
                    variant="night_curtain_sfold",
                    layer="night",
                    material_key=material_key,
                    est_width_tmm=36576,
                    est_height_tmm=27432,
                    applied_rule_id="rule-1",
                    applied_rate_card_version=1,
                    standard_rate_sen=8000,
                    rate_sen=8000,
                    billed_qty="12",
                    billed_unit="ft",
                    line_total_sen=96000,
                    material_deferred=True,
                )
            ],
        ),
    )
    session.commit()


def move(
    session: Session,
    to: str,
    *,
    reason: str | None = None,
    at: datetime | None = None,
    event_id: str | None = None,
    by: User | None = None,
):
    return advance_order_status(
        session,
        StatusChangeIn(
            order_id=ORDER_ID,
            event_id=event_id or str(uuid.uuid4()),
            to=to,
            reason=reason,
            at=at or CONFIRMED_AT + timedelta(days=1),
        ),
        by=by,
    )


def measure(session: Session) -> None:
    session.get(OrderLine, LINE_ID).is_site_measured = True
    session.commit()


def choose_material(session: Session) -> None:
    session.get(OrderLine, LINE_ID).material_key = "tbl"
    session.commit()


class TestWalkingThePipeline:
    def test_a_legal_step_moves_the_order_and_writes_its_event(self, db) -> None:
        with db() as session:
            seed(session)
            result = move(session, "measurement_booked")
            session.commit()

            assert result.refused_because is None
            assert result.status == "measurement_booked"
            assert session.get(Order, ORDER_ID).status == "measurement_booked"
            events = session.scalars(select(OrderEvent)).all()
            assert [e.event for e in events] == ["measurement_booked"]

    def test_the_whole_pipeline_walks_end_to_end(self, db) -> None:
        with db() as session:
            seed(session)
            assert move(session, "measurement_booked").status == "measurement_booked"
            measure(session)
            assert move(session, "measured").status == "measured"
            choose_material(session)
            assert move(session, "material_selected").status == "material_selected"
            assert move(session, "in_production").status == "in_production"
            assert move(session, "ready").status == "ready"
            assert move(session, "installed").status == "installed"
            assert move(session, "closed").status == "closed"
            session.commit()

            assert session.get(Order, ORDER_ID).status == "closed"
            assert len(session.scalars(select(OrderEvent)).all()) == 7

    def test_it_records_who_moved_it(self, db) -> None:
        # An event with nobody on it is the one somebody will be asked about a
        # year later.
        with db() as session:
            seed(session)
            user = User(id=str(uuid.uuid4()), name="Ah Lian", role="staff")
            session.add(user)
            session.flush()
            move(session, "measurement_booked", by=user)
            session.commit()
            assert session.scalars(select(OrderEvent)).one().by_user_id == user.id


class TestARetryIsHarmless:
    def test_the_same_event_applied_twice_changes_nothing(self, db) -> None:
        event_id = str(uuid.uuid4())
        with db() as session:
            seed(session)
            first = move(session, "measurement_booked", event_id=event_id)
            session.commit()
            second = move(session, "measurement_booked", event_id=event_id)
            session.commit()

            assert first.duplicate is False
            assert second.duplicate is True
            assert second.status == "measurement_booked"
            assert len(session.scalars(select(OrderEvent)).all()) == 1

    def test_idempotency_is_on_the_move_not_the_order(self, db) -> None:
        # An order walks the pipeline many times. Keying on the order would
        # make the second legitimate step look like a retry of the first.
        with db() as session:
            seed(session)
            move(session, "measurement_booked")
            session.commit()
            measure(session)
            result = move(session, "measured")
            session.commit()

            assert result.duplicate is False
            assert result.status == "measured"
            assert len(session.scalars(select(OrderEvent)).all()) == 2


class TestARefusalIsReportedNotRaised:
    def test_a_skipped_step_leaves_the_order_where_it_was(self, db) -> None:
        with db() as session:
            seed(session)
            result = move(session, "in_production")
            session.commit()

            assert result.refused_because == "not_a_transition"
            assert result.status == "confirmed"
            assert session.get(Order, ORDER_ID).status == "confirmed"
            assert session.scalars(select(OrderEvent)).all() == []

    def test_measured_is_refused_while_a_line_has_no_final_dimensions(self, db) -> None:
        # Five of six windows measured is not a measured order. This is the
        # guard the order push cannot reach, because a push always starts from
        # confirmed.
        with db() as session:
            seed(session)
            move(session, "measurement_booked")
            session.commit()

            result = move(session, "measured")
            session.commit()
            assert result.refused_because == "lines_not_measured"
            assert session.get(Order, ORDER_ID).status == "measurement_booked"

            measure(session)
            assert move(session, "measured").refused_because is None

    def test_material_selected_is_refused_while_one_line_still_defers(self, db) -> None:
        with db() as session:
            seed(session)
            move(session, "measurement_booked")
            measure(session)
            move(session, "measured")
            session.commit()

            result = move(session, "material_selected")
            session.commit()
            assert result.refused_because == "material_not_chosen"
            assert session.get(Order, ORDER_ID).status == "measured"

            choose_material(session)
            assert move(session, "material_selected").refused_because is None

    def test_an_unknown_status_is_refused_rather_than_guessed(self, db) -> None:
        with db() as session:
            seed(session)
            result = move(session, "awaiting_paint")
            session.commit()
            assert result.refused_because == "unknown_status"
            assert session.get(Order, ORDER_ID).status == "confirmed"

    def test_a_move_for_an_order_that_has_not_arrived_says_so(self, db) -> None:
        # The outbox is FIFO so this should not happen, but writing an event
        # that points at nothing is worse than saying plainly that it cannot.
        with db() as session:
            result = advance_order_status(
                session,
                StatusChangeIn(
                    order_id=ORDER_ID,
                    event_id=str(uuid.uuid4()),
                    to="measurement_booked",
                    at=CONFIRMED_AT,
                ),
            )
            session.commit()
            assert result.refused_because == "unknown_order"
            assert session.scalars(select(OrderEvent)).all() == []


class TestCancelling:
    def test_it_needs_a_reason_and_stores_it(self, db) -> None:
        with db() as session:
            seed(session)
            refused = move(session, "cancelled", reason="   ")
            session.commit()
            assert refused.refused_because == "no_reason"
            assert session.get(Order, ORDER_ID).status == "confirmed"

            ok = move(session, "cancelled", reason="customer bought elsewhere")
            session.commit()
            assert ok.status == "cancelled"
            assert (
                session.scalars(select(OrderEvent)).one().note
                == "customer bought elsewhere"
            )

    def test_the_deposit_is_left_exactly_where_it_was(self, db) -> None:
        # §13 B3 is unanswered: forfeit, partial or credit. Zeroing it here
        # would be a decision nobody made, written into the ledger.
        with db() as session:
            seed(session)
            move(session, "cancelled", reason="customer bought elsewhere")
            session.commit()
            assert session.get(Order, ORDER_ID).deposit_paid_sen == 30000

    def test_a_cancelled_order_stops_moving(self, db) -> None:
        with db() as session:
            seed(session)
            move(session, "cancelled", reason="customer bought elsewhere")
            session.commit()

            for to in ("confirmed", "measurement_booked", "closed"):
                result = move(session, to, reason="a perfectly good reason")
                session.commit()
                assert result.refused_because == "terminal", to
            assert len(session.scalars(select(OrderEvent)).all()) == 1

"""Accepting a confirmed order from a device. SPEC.md §6.3 and §9.2.

A deposit is what confirms an order, so an order arriving here is money already
taken. That sets the bar for everything below: a retry must not produce a second
order, a retry must hand back the *same* number, and nothing may reject the push
outright — refusing it would lose the sale and leave the only record of it on one
handset at a fair.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import OrderEventIn, OrderIn, OrderLineIn, PriceOverrideIn
from app.models.db import (
    Base,
    Order,
    OrderEvent,
    OrderLine,
    PriceOverride,
    User,
)
from app.services.ingest import push_order
from app.services.order_numbers import BadBranchCode, issue_order_no

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


def a_line(**over) -> OrderLineIn:
    fields = {
        "id": str(uuid.uuid4()),
        "quote_line_id": str(uuid.uuid4()),
        "sort_order": 0,
        "room": "Living room",
        "variant": "night_curtain_sfold",
        "layer": "night",
        "est_width_tmm": 36576,
        "est_height_tmm": 27432,
        "applied_rule_id": "rule-1",
        "applied_rate_card_version": 1,
        "standard_rate_sen": 8000,
        "rate_sen": 8000,
        "billed_qty": "12",
        "billed_unit": "ft",
        "line_total_sen": 96000,
        "material_deferred": True,
    }
    fields.update(over)
    return OrderLineIn(**fields)


def an_order(**over) -> OrderIn:
    fields = {
        "id": str(uuid.uuid4()),
        "quote_id": str(uuid.uuid4()),
        "channel": "fair",
        "pinned_rate_card_version": 1,
        "estimate_total_sen": 96000,
        "deposit_paid_sen": 30000,
        "confirmed_at": CONFIRMED_AT,
        "lines": [a_line()],
    }
    fields.update(over)
    return OrderIn(**fields)


class TestTheOrderNumber:
    def test_it_is_issued_here_and_the_device_never_sends_one(self) -> None:
        # There is no order_no field to send. A device that could set one would
        # collide with every other device offline at the same fair, on a
        # document the customer takes away.
        assert "order_no" not in OrderIn.model_fields

    def test_the_format_reads_as_branch_month_sequence(self, db) -> None:
        with db() as session:
            first = issue_order_no(session, confirmed_at=CONFIRMED_AT.date())
            second = issue_order_no(session, confirmed_at=CONFIRMED_AT.date())
        assert first == "MLK-2608-0001"
        assert second == "MLK-2608-0002"

    def test_the_counter_restarts_each_month(self, db) -> None:
        with db() as session:
            august = issue_order_no(session, confirmed_at=datetime(2026, 8, 31).date())
            september = issue_order_no(
                session, confirmed_at=datetime(2026, 9, 1).date()
            )
        assert august == "MLK-2608-0001"
        assert september == "MLK-2609-0001"

    def test_a_second_branch_does_not_renumber_the_first(self, db) -> None:
        with db() as session:
            issue_order_no(session, confirmed_at=CONFIRMED_AT.date())
            other = issue_order_no(
                session, confirmed_at=CONFIRMED_AT.date(), branch="KL"
            )
            back = issue_order_no(session, confirmed_at=CONFIRMED_AT.date())
        assert other == "KL-2608-0001"
        assert back == "MLK-2608-0002"

    @pytest.mark.parametrize("branch", ["", "m", "melaka-1", "MLK ", "M L", "TOOLONGX"])
    def test_a_branch_code_that_cannot_go_on_paper_is_refused(
        self, db, branch: str
    ) -> None:
        with db() as session, pytest.raises(BadBranchCode):
            issue_order_no(session, confirmed_at=CONFIRMED_AT.date(), branch=branch)


class TestPushingAnOrder:
    def test_it_is_stored_with_its_lines_and_events(self, db) -> None:
        event_id = str(uuid.uuid4())
        payload = an_order(
            events=[
                OrderEventIn(id=event_id, event="confirmed", at=CONFIRMED_AT),
            ]
        )
        with db() as session:
            result = push_order(session, payload)
            session.commit()

        assert result.duplicate is False
        assert result.order_no == "MLK-2608-0001"

        with db() as session:
            order = session.get(Order, payload.id)
            assert order is not None
            assert order.order_no == "MLK-2608-0001"
            assert order.status == "confirmed"
            assert order.estimate_total_sen == 96000
            assert len(session.scalars(select(OrderLine)).all()) == 1
            assert session.scalars(select(OrderEvent)).one().event == "confirmed"

    def test_a_retry_takes_no_second_order_and_reuses_the_number(self, db) -> None:
        # The failure this prevents: a fair's connection drops, the device
        # cannot tell whether the server got it, and sends again. Two orders
        # for one RM300 is the expensive outcome.
        payload = an_order()
        with db() as session:
            first = push_order(session, payload)
            session.commit()
        with db() as session:
            second = push_order(session, payload)
            session.commit()

        assert first.duplicate is False
        assert second.duplicate is True
        assert second.order_no == first.order_no

        with db() as session:
            assert len(session.scalars(select(Order)).all()) == 1
            assert len(session.scalars(select(OrderLine)).all()) == 1

    def test_the_pusher_is_taken_from_the_session_not_the_body(self, db) -> None:
        # A device must not be able to claim the order was somebody else's.
        # There is no field for it, and the caller passes the authenticated
        # user.
        assert "confirmed_by_user_id" not in OrderIn.model_fields

        payload = an_order()
        with db() as session:
            user = User(id=str(uuid.uuid4()), name="Boss", role="admin")
            session.add(user)
            session.flush()
            push_order(session, payload, confirmed_by=user)
            session.commit()
            assert session.get(Order, payload.id).confirmed_by_user_id == user.id

    def test_the_quote_is_referenced_and_left_alone(self, db) -> None:
        # §6.3: the quote is what the measurement team reads and what the
        # variance report compares against. Consuming it would destroy the
        # estimate the comparison needs.
        payload = an_order()
        with db() as session:
            push_order(session, payload)
            session.commit()
            order = session.get(Order, payload.id)
            assert order.quote_id == payload.quote_id
            # The line keeps its own trail back to the quote line it copied.
            assert (
                session.scalars(select(OrderLine)).one().quote_line_id
                == payload.lines[0].quote_line_id
            )


class TestProvenance:
    """Where a line's dimensions came from. SPEC.md Phase 8.

    Every order pushed before this field existed was typed by hand -- so the
    default, and every line that omits the field, must read as ``manual``.
    """

    def test_a_plain_line_defaults_to_manual(self, db) -> None:
        payload = an_order(lines=[a_line()])
        with db() as session:
            push_order(session, payload)
            session.commit()
            line = session.scalars(select(OrderLine)).one()
            assert line.measurement_source == "manual"
            assert line.source_project_id is None

    def test_a_library_sourced_line_keeps_its_trail(self, db) -> None:
        project_id = str(uuid.uuid4())
        unit_type_id = str(uuid.uuid4())
        payload = an_order(
            lines=[
                a_line(
                    measurement_source="project_library",
                    source_project_id=project_id,
                    source_unit_type_id=unit_type_id,
                    source_version=2,
                )
            ]
        )
        with db() as session:
            push_order(session, payload)
            session.commit()
            line = session.scalars(select(OrderLine)).one()
            assert line.measurement_source == "project_library"
            assert line.source_project_id == project_id
            assert line.source_unit_type_id == unit_type_id
            assert line.source_version == 2

    def test_a_device_cannot_claim_a_site_measurement_at_push_time(self, db) -> None:
        # A line only earns `site_measurement` through the dedicated
        # measurement endpoint, after a real site visit -- never by simply
        # being pushed that way at order confirmation.
        with pytest.raises(ValueError):
            a_line(measurement_source="site_measurement")

    def test_a_room_sourced_line_carries_no_width_but_carries_its_area(
        self, db
    ) -> None:
        # A saved room's area does not reduce to one rectangle, so
        # est_width_tmm/est_height_tmm are genuinely absent -- the line
        # prices from direct_area_sqft instead, copied straight through
        # from the quote line it was confirmed from.
        payload = an_order(
            lines=[
                a_line(
                    variant="spc_4mm_1mm",
                    est_width_tmm=None,
                    est_height_tmm=None,
                    direct_area_sqft="700/3",
                    measurement_source="project_library",
                )
            ]
        )
        with db() as session:
            push_order(session, payload)
            session.commit()
            line = session.scalars(select(OrderLine)).one()
            assert line.est_width_tmm is None
            assert line.direct_area_sqft == "700/3"


class TestTheStatusIsRevalidated:
    def test_a_device_may_push_a_confirmed_order(self, db) -> None:
        with db() as session:
            result = push_order(session, an_order(status="confirmed"))
            session.commit()
        assert result.status_refused_because is None

    def test_a_legal_first_step_is_accepted(self, db) -> None:
        payload = an_order(status="measurement_booked")
        with db() as session:
            result = push_order(session, payload)
            session.commit()
            assert result.status_refused_because is None
            assert session.get(Order, payload.id).status == "measurement_booked"

    def test_a_skipped_step_is_not_applied_but_the_order_still_lands(self, db) -> None:
        # The money has been taken. Refusing the push would lose the sale and
        # leave the only record of it on one handset.
        payload = an_order(status="in_production")
        with db() as session:
            result = push_order(session, payload)
            session.commit()

            assert result.status_refused_because == "not_a_transition"
            order = session.get(Order, payload.id)
            assert order is not None
            assert (
                order.status == "confirmed"
            ), "a device must not drag the server past a step it skipped"
            assert order.order_no == "MLK-2608-0001"

    def test_a_status_this_build_does_not_know_is_not_applied(self, db) -> None:
        # Guessing which stage a job is at would put a real order in the wrong
        # column of every report, quietly.
        payload = an_order(status="awaiting_paint")
        with db() as session:
            result = push_order(session, payload)
            session.commit()
            assert result.status_refused_because == "unknown_status"
            assert session.get(Order, payload.id).status == "confirmed"

    def test_a_push_can_only_ever_advance_one_step_from_confirmed(self, db) -> None:
        # Everything past measurement_booked is refused here as
        # `not_a_transition` rather than by a line guard, because a push always
        # starts from confirmed and confirmed has exactly two edges. The line
        # guards live on the status route, which is where a job actually walks
        # the pipeline.
        for status, refusal in [
            ("measurement_booked", None),
            ("cancelled", "no_reason"),
            ("measured", "not_a_transition"),
            ("material_selected", "not_a_transition"),
            ("in_production", "not_a_transition"),
            ("ready", "not_a_transition"),
            ("installed", "not_a_transition"),
            ("closed", "not_a_transition"),
        ]:
            payload = an_order(status=status, lines=[a_line(is_site_measured=True)])
            with db() as session:
                result = push_order(session, payload)
                session.commit()
                assert result.status_refused_because == refusal, status

    def test_a_cancelled_order_cannot_arrive_in_a_single_push(self, db) -> None:
        # Cancelling needs a reason and the order payload carries none — the
        # reason belongs on the event. An order that was raised and cancelled
        # before it ever synced still lands as confirmed, and the cancellation
        # goes through the status route with its reason attached.
        payload = an_order(status="cancelled")
        with db() as session:
            result = push_order(session, payload)
            session.commit()
            assert result.status_refused_because == "no_reason"
            assert session.get(Order, payload.id).status == "confirmed"


class TestOverridesAreRevalidated:
    def test_a_good_override_is_stored(self, db) -> None:
        line = a_line()
        payload = an_order(
            lines=[line],
            overrides=[
                PriceOverrideIn(
                    id=str(uuid.uuid4()),
                    order_line_id=line.id,
                    before_sen=96000,
                    after_sen=90000,
                    reason="matched a competitor quote",
                    admin_user_id="u-boss",
                    at=CONFIRMED_AT,
                )
            ],
        )
        with db() as session:
            result = push_order(session, payload)
            session.commit()

            assert result.overrides_refused == {}
            row = session.scalars(select(PriceOverride)).one()
            assert row.before_sen == 96000
            assert row.after_sen == 90000
            assert row.admin_user_id == "u-boss"
            assert row.order_id == payload.id

    def test_a_reason_below_the_floor_never_reaches_the_service(self) -> None:
        # Pydantic rejects it at the door, so a row that cannot say why can
        # never be constructed in the first place. §6.5.
        with pytest.raises(ValueError):
            PriceOverrideIn(
                id=str(uuid.uuid4()),
                order_line_id=str(uuid.uuid4()),
                before_sen=96000,
                after_sen=90000,
                reason="no",
                admin_user_id="u-boss",
                at=CONFIRMED_AT,
            )

    def test_an_override_of_a_line_not_in_the_push_is_dropped(self, db) -> None:
        # An audit row pointing at no line is a row the weekly review cannot
        # explain, which is the one thing §6.5 needs it to do.
        stray = PriceOverrideIn(
            id=str(uuid.uuid4()),
            order_line_id=str(uuid.uuid4()),
            before_sen=96000,
            after_sen=90000,
            reason="matched a competitor quote",
            admin_user_id="u-boss",
            at=CONFIRMED_AT,
        )
        payload = an_order(overrides=[stray])
        with db() as session:
            result = push_order(session, payload)
            session.commit()

            assert result.overrides_refused == {stray.id: "unknown_line"}
            assert session.scalars(select(PriceOverride)).all() == []
            # The order itself still landed. The money was taken.
            assert session.get(Order, payload.id) is not None

    def test_an_override_that_changes_nothing_is_dropped(self, db) -> None:
        # Noise is what stops the weekly review being read at all.
        line = a_line()
        same = PriceOverrideIn(
            id=str(uuid.uuid4()),
            order_line_id=line.id,
            before_sen=96000,
            after_sen=96000,
            reason="checked against the card",
            admin_user_id="u-boss",
            at=CONFIRMED_AT,
        )
        payload = an_order(lines=[line], overrides=[same])
        with db() as session:
            result = push_order(session, payload)
            session.commit()
            assert result.overrides_refused == {same.id: "no_change"}
            assert session.scalars(select(PriceOverride)).all() == []

    def test_one_bad_override_does_not_take_the_good_one_with_it(self, db) -> None:
        line = a_line()
        good = PriceOverrideIn(
            id=str(uuid.uuid4()),
            order_line_id=line.id,
            before_sen=96000,
            after_sen=90000,
            reason="matched a competitor quote",
            admin_user_id="u-boss",
            at=CONFIRMED_AT,
        )
        bad = PriceOverrideIn(
            id=str(uuid.uuid4()),
            order_line_id=str(uuid.uuid4()),
            before_sen=96000,
            after_sen=90000,
            reason="matched a competitor quote",
            admin_user_id="u-boss",
            at=CONFIRMED_AT,
        )
        payload = an_order(lines=[line], overrides=[good, bad])
        with db() as session:
            result = push_order(session, payload)
            session.commit()

            assert set(result.overrides_refused) == {bad.id}
            assert session.scalars(select(PriceOverride)).one().id == good.id

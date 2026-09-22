"""What is waiting for a site visit. SPEC.md §11 Phase 5.

Three things carry the weight here.

**The grouping.** §11 wants trips grouped by project, and there is no project
library until Phase 8, so the key is the customer's normalised phone -- the same
key a rate lock uses. A customer who typed `012-345 6789` in July and
`0123456789` in August is one trip, and a queue that made them two would send
somebody to the same house twice.

**Who is in the queue at all.** Everything at `confirmed` or
`measurement_booked`, including an order with nothing left to measure. §13 C7 is
unanswered so the pipeline refuses to skip those steps, and filtering on the
unmeasured count would make exactly those orders invisible forever.

**The clock.** `waiting_days` is injected, because a number somebody reads off a
screen has to be one a test can pin.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import OrderIn, OrderLineIn, StatusChangeIn
from app.models.db import Base, Order
from app.services.ingest import advance_order_status, push_order
from app.services.measurement_queue import measurement_queue

#: A deposit taken at the August fair, and a "today" three weeks later.
CONFIRMED = datetime(2026, 8, 10, 14, 0, tzinfo=UTC)
NOW = datetime(2026, 8, 31, 9, 0, tzinfo=UTC)


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
        "applied_rule_id": "rule-1",
        "applied_rate_card_version": 1,
        "standard_rate_sen": 4600,
        "rate_sen": 4600,
        "billed_qty": "12",
        "billed_unit": "ft",
        "line_total_sen": 55200,
    }
    fields.update(over)
    return OrderLineIn(**fields)


def an_order(session: Session, **over) -> OrderIn:
    fields = {
        "id": str(uuid.uuid4()),
        "quote_id": str(uuid.uuid4()),
        "channel": "fair",
        "pinned_rate_card_version": 1,
        "estimate_total_sen": 55200,
        "deposit_paid_sen": 30000,
        "confirmed_at": CONFIRMED,
        "lines": [a_line()],
    }
    fields.update(over)
    payload = OrderIn(**fields)
    push_order(session, payload)
    return payload


def at_status(session: Session, order_id: str, status: str) -> None:
    """Put an order at a stage the pipeline cannot reach in one step.

    Set on the row rather than walked: `push_order` only accepts a status one
    `advance_order` away from `confirmed`, and reaching `in_production` properly
    means satisfying the measured and material guards. What is under test here
    is which statuses the queue selects, so stating the status directly is the
    premise, not a shortcut around one.
    """
    session.get(Order, order_id).status = status
    session.flush()


def book(session: Session, order_id: str, *, at: datetime) -> None:
    advance_order_status(
        session,
        StatusChangeIn(
            order_id=order_id,
            event_id=str(uuid.uuid4()),
            to="measurement_booked",
            at=at,
        ),
    )


class TestWhoIsInTheQueue:
    def test_a_confirmed_order_is_waiting_for_a_visit(self, db) -> None:
        with db() as session:
            payload = an_order(session, customer_name="Ah Lian")
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert queue.total_orders == 1
            (group,) = queue.groups
            (job,) = group.jobs
            assert job.order_id == payload.id
            assert job.status == "confirmed"
            assert job.booked_at is None

    def test_a_booked_visit_is_still_in_the_queue(self, db) -> None:
        # Booked is not done. The trip has not happened yet.
        with db() as session:
            payload = an_order(session)
            book(session, payload.id, at=CONFIRMED + timedelta(days=2))
            session.commit()

            queue = measurement_queue(session, now=NOW)

            (group,) = queue.groups
            (job,) = group.jobs
            assert job.status == "measurement_booked"
            assert group.booked_count == 1

    @pytest.mark.parametrize(
        "status",
        ["measured", "material_selected", "in_production", "ready", "installed"],
    )
    def test_a_measured_order_has_left_the_queue(self, db, status) -> None:
        with db() as session:
            payload = an_order(session)
            at_status(session, payload.id, status)
            session.commit()

            assert measurement_queue(session, now=NOW).total_orders == 0

    def test_a_cancelled_order_is_not_a_trip(self, db) -> None:
        with db() as session:
            payload = an_order(session)
            at_status(session, payload.id, "cancelled")
            session.commit()

            assert measurement_queue(session, now=NOW).total_orders == 0

    def test_an_order_with_nothing_left_to_measure_stays_in_the_queue(self, db) -> None:
        # §13 C7 is unanswered, so the pipeline refuses to skip the measurement
        # steps. An order that vanished from this screen because it had no
        # unmeasured lines would sit at `confirmed` forever with nobody able to
        # see it, which is the failure nobody would notice.
        with db() as session:
            an_order(
                session,
                # Both, because both are what a filter would read: the order's
                # own flag and the state of every line under it.
                has_unmeasured_lines=False,
                lines=[a_line(is_site_measured=True)],
            )
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert queue.total_orders == 1
            (job,) = queue.groups[0].jobs
            assert job.line_count == 1
            assert job.unmeasured_line_count == 0

    def test_an_empty_queue_says_so_rather_than_failing(self, db) -> None:
        with db() as session:
            assert measurement_queue(session, now=NOW) == measurement_queue(
                session, now=NOW
            )
            queue = measurement_queue(session, now=NOW)
            assert queue.groups == []
            assert queue.total_orders == 0


class TestOneTripCoversSeveralUnits:
    def test_two_orders_for_one_phone_are_one_trip(self, db) -> None:
        with db() as session:
            an_order(session, customer_phone="0123456789", customer_name="Ah Lian")
            an_order(session, customer_phone="0123456789", customer_name="Ah Lian")
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert queue.total_orders == 2
            (group,) = queue.groups
            assert len(group.jobs) == 2
            assert group.grouped_by_phone is True

    def test_a_phone_typed_two_ways_is_still_one_trip(self, db) -> None:
        # The bug this whole area already had once: a raw-string key would make
        # these two houses, and somebody would drive to Melaka twice.
        with db() as session:
            an_order(session, customer_phone="012-345 6789")
            an_order(session, customer_phone="+60123456789")
            session.commit()

            (group,) = measurement_queue(session, now=NOW).groups

            assert len(group.jobs) == 2
            assert group.key == "unzoned:phone:0123456789"

    def test_different_customers_are_different_trips(self, db) -> None:
        with db() as session:
            an_order(session, customer_phone="0123456789")
            an_order(session, customer_phone="0129999999")
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert len(queue.groups) == 2
            assert queue.total_orders == 2

    def test_orders_with_no_phone_are_never_pooled_together(self, db) -> None:
        # Pooling them would invent a trip that does not exist and send
        # somebody out for it.
        with db() as session:
            an_order(session, customer_phone=None, customer_name="Walk-in")
            an_order(session, customer_phone=None, customer_name="Another")
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert len(queue.groups) == 2
            assert all(group.grouped_by_phone is False for group in queue.groups)

    def test_a_phone_too_short_to_be_one_does_not_group(self, db) -> None:
        # `normalise_phone` refuses anything under nine digits. Two people who
        # typed "123" are not the same house.
        with db() as session:
            an_order(session, customer_phone="123")
            an_order(session, customer_phone="123")
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert len(queue.groups) == 2
            assert all(group.grouped_by_phone is False for group in queue.groups)

    def test_a_name_on_a_later_order_names_the_trip(self, db) -> None:
        with db() as session:
            an_order(session, customer_phone="0123456789", customer_name=None)
            an_order(
                session,
                customer_phone="0123456789",
                customer_name="Ah Lian",
                confirmed_at=CONFIRMED + timedelta(days=1),
            )
            session.commit()

            (group,) = measurement_queue(session, now=NOW).groups

            assert group.customer_name == "Ah Lian"


class TestWhoHasWaitedLongest:
    def test_the_oldest_deposit_is_at_the_top(self, db) -> None:
        with db() as session:
            an_order(
                session,
                customer_phone="0129999999",
                confirmed_at=CONFIRMED + timedelta(days=10),
            )
            an_order(session, customer_phone="0123456789", confirmed_at=CONFIRMED)
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert [g.key for g in queue.groups] == [
                "unzoned:phone:0123456789",
                "unzoned:phone:0129999999",
            ]

    def test_a_group_waits_as_long_as_its_oldest_order(self, db) -> None:
        with db() as session:
            an_order(
                session,
                customer_phone="0123456789",
                confirmed_at=CONFIRMED + timedelta(days=15),
            )
            an_order(session, customer_phone="0123456789", confirmed_at=CONFIRMED)
            session.commit()

            (group,) = measurement_queue(session, now=NOW).groups

            assert group.oldest_confirmed_at == CONFIRMED
            assert group.waiting_days == 20

    def test_waiting_days_counts_whole_days_only(self, db) -> None:
        with db() as session:
            an_order(session, confirmed_at=NOW - timedelta(hours=47))
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.waiting_days == 1

    def test_a_handset_clock_ahead_of_the_server_never_shows_a_negative(
        self, db
    ) -> None:
        # A device can be hours ahead. "-2 days waiting" reads as a bug in the
        # queue rather than a bug in one phone.
        with db() as session:
            an_order(session, confirmed_at=NOW + timedelta(days=2))
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.waiting_days == 0


class TestZoneGrouping:
    """§13 C10, answered: zone first, then customer within it."""

    def test_same_phone_different_zones_are_two_trips(self, db) -> None:
        # A zone-only key would merge these back into one trip and send
        # somebody straight from Muar to KL on the same visit.
        with db() as session:
            an_order(session, customer_phone="0123456789", delivery_zone_id="zone-kl")
            an_order(session, customer_phone="0123456789", delivery_zone_id="zone-muar")
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert len(queue.groups) == 2
            assert {g.delivery_zone_id for g in queue.groups} == {
                "zone-kl",
                "zone-muar",
            }

    def test_same_phone_same_zone_stays_one_trip(self, db) -> None:
        with db() as session:
            an_order(session, customer_phone="0123456789", delivery_zone_id="zone-kl")
            an_order(session, customer_phone="0123456789", delivery_zone_id="zone-kl")
            session.commit()

            (group,) = measurement_queue(session, now=NOW).groups

            assert len(group.jobs) == 2
            assert group.delivery_zone_id == "zone-kl"

    def test_an_order_with_no_zone_lands_in_the_unzoned_bucket(self, db) -> None:
        with db() as session:
            an_order(session, delivery_zone_id=None)
            session.commit()

            (group,) = measurement_queue(session, now=NOW).groups

            assert group.delivery_zone_id is None
            assert group.key.startswith("unzoned:")

    def test_a_zone_missing_from_the_lookup_never_crashes(self, db) -> None:
        # A zone id can outlive the card that named it -- renamed or removed
        # since the order was placed. The group still forms; it just has no
        # label to show.
        with db() as session:
            an_order(session, delivery_zone_id="zone-that-no-longer-exists")
            session.commit()

            (group,) = measurement_queue(session, now=NOW, zone_labels={}).groups

            assert group.delivery_zone_id == "zone-that-no-longer-exists"
            assert group.delivery_zone_labels is None

    def test_a_known_zone_carries_its_labels(self, db) -> None:
        with db() as session:
            an_order(session, delivery_zone_id="zone-kl")
            session.commit()

            (group,) = measurement_queue(
                session,
                now=NOW,
                zone_labels={"zone-kl": {"zh": "吉隆坡", "en": "KL", "ms": "KL"}},
            ).groups

            assert group.delivery_zone_labels == {
                "zh": "吉隆坡",
                "en": "KL",
                "ms": "KL",
            }

    def test_the_zone_with_the_most_overdue_customer_sorts_first(self, db) -> None:
        # zone-b would sort after zone-a alphabetically, and has fewer orders
        # -- neither is the rule. It holds the oldest deposit, so it goes
        # first: route efficiency must never bury an overdue customer.
        with db() as session:
            an_order(
                session,
                customer_phone="0121111111",
                delivery_zone_id="zone-a",
                confirmed_at=CONFIRMED + timedelta(days=20),
            )
            an_order(
                session,
                customer_phone="0122222222",
                delivery_zone_id="zone-a",
                confirmed_at=CONFIRMED + timedelta(days=25),
            )
            an_order(
                session,
                customer_phone="0123333333",
                delivery_zone_id="zone-b",
                confirmed_at=CONFIRMED,
            )
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert [g.delivery_zone_id for g in queue.groups] == [
                "zone-b",
                "zone-a",
                "zone-a",
            ]

    def test_within_a_zone_the_oldest_first_order_is_preserved(self, db) -> None:
        with db() as session:
            an_order(
                session,
                customer_phone="0121111111",
                delivery_zone_id="zone-a",
                confirmed_at=CONFIRMED + timedelta(days=10),
            )
            an_order(
                session,
                customer_phone="0122222222",
                delivery_zone_id="zone-a",
                confirmed_at=CONFIRMED,
            )
            session.commit()

            queue = measurement_queue(session, now=NOW)

            assert [g.customer_phone for g in queue.groups] == [
                "0122222222",
                "0121111111",
            ]


class TestWhatTheMeasurerNeedsToKnow:
    def test_the_counts_say_how_big_the_visit_is(self, db) -> None:
        with db() as session:
            an_order(
                session,
                lines=[
                    a_line(sort_order=0),
                    a_line(sort_order=1, is_site_measured=True),
                    a_line(sort_order=2, material_deferred=True),
                ],
            )
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.line_count == 3
            assert job.unmeasured_line_count == 2
            assert job.material_pending_count == 1

    def test_a_chosen_material_is_no_longer_pending(self, db) -> None:
        # §13 B7: a deferred line is quoted at the dearest option in its group.
        # Once somebody has picked, it is not a decision waiting on site.
        with db() as session:
            an_order(
                session,
                lines=[a_line(material_deferred=True, material_key="korea_a")],
            )
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.material_pending_count == 0

    def test_booked_at_comes_from_the_history(self, db) -> None:
        # `orders` has no booking column and is not getting one -- the event is
        # already recorded, and a column beside it would drift.
        booked = CONFIRMED + timedelta(days=3)
        with db() as session:
            payload = an_order(session)
            book(session, payload.id, at=booked)
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.booked_at == booked

    def test_booking_twice_writes_no_second_history_row(self, db) -> None:
        # The second call is refused as `already_there`, so there is nothing
        # for the queue to choose between. Worth pinning: it is why `_booked_at`
        # needs no rule for picking among several bookings, only the aggregate
        # a GROUP BY requires.
        booked = CONFIRMED + timedelta(days=3)
        with db() as session:
            payload = an_order(session)
            book(session, payload.id, at=booked)
            book(session, payload.id, at=CONFIRMED + timedelta(days=9))
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.booked_at == booked

    def test_a_group_says_how_many_of_its_jobs_are_booked(self, db) -> None:
        # Zero is the group nobody has called yet.
        with db() as session:
            first = an_order(session, customer_phone="0123456789")
            an_order(session, customer_phone="0123456789")
            book(session, first.id, at=CONFIRMED + timedelta(days=1))
            session.commit()

            (group,) = measurement_queue(session, now=NOW).groups

            assert group.booked_count == 1
            assert len(group.jobs) == 2

    def test_a_job_carries_the_estimate_but_no_rate(self, db) -> None:
        # Phase 6 reprices, at the held version. Nothing on this screen should
        # let somebody do it from here.
        with db() as session:
            an_order(session, estimate_total_sen=55200)
            session.commit()

            (job,) = measurement_queue(session, now=NOW).groups[0].jobs

            assert job.estimate_total_sen == 55200
            assert not hasattr(job, "rate_sen")

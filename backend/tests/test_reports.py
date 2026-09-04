"""The Phase 5 reports. SPEC.md §11, §6.3, §8.5.

What is worth testing here is not that the arithmetic adds up -- it is the
places where a report could be quietly wrong in a way somebody would act on:

* a variance column read as a skill measure when the whole column is biased by
  design, and an order whose final came out *above* its estimate averaged away
  inside it (§8.5 says that cannot happen, so it is not a statistic);
* an ageing bucket that catches a row twice or drops it;
* an estimated balance presented as a debt when §8.5 makes it an upper bound;
* a cancelled order's money appearing in a total while §13 B3 is unanswered.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import CategoryLockIn, OrderIn, OrderLineIn
from app.core.security import hash_pin
from app.models.db import Base, Order, User
from app.services.ingest import publish_card, push_category_lock, push_order
from app.services.reports import (
    fair_performance,
    outstanding_balances,
    variance_by_salesperson,
)

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)
STANDARD = json.loads(
    (ROOT / "shared" / "rate-card-standard.json").read_text(encoding="utf-8")
)

CONFIRMED = datetime(2026, 8, 30, 14, 0, tzinfo=UTC)
NOW = datetime(2026, 9, 4, 9, 0, tzinfo=UTC)


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


def an_order(
    session: Session,
    *,
    final_sen: int | None = None,
    sold_by: User | None = None,
    **over,
) -> str:
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
    # The salesperson comes from the authenticated session, not the payload:
    # a device does not get to say who took the deposit.
    push_order(session, payload, confirmed_by=sold_by)

    if final_sen is not None:
        # Set on the row: Phase 6 is what will write this, and it does not
        # exist yet. The column does, and it is what the report reads.
        session.get(Order, payload.id).final_total_sen = final_sen
        session.flush()
    return payload.id


def a_person(session: Session, name: str) -> User:
    user = User(
        id=str(uuid.uuid4()),
        name=name,
        phone=f"011{uuid.uuid4().int % 10_000_000:07d}",
        role="staff",
        pin_hash=hash_pin("4821"),
    )
    session.add(user)
    session.flush()
    return user


class TestVarianceBySalesperson:
    def test_it_says_when_nothing_has_been_priced_yet(self, db) -> None:
        # Phase 6 sets the final price. Until then an empty table would be
        # indistinguishable from a query that failed.
        with db() as session:
            an_order(session)
            session.commit()

            report = variance_by_salesperson(session)

            assert report.nothing_priced_yet is True
            assert report.rows[0].orders_awaiting_final == 1
            assert report.rows[0].orders_priced == 0

    def test_the_variance_is_final_minus_estimate(self, db) -> None:
        with db() as session:
            who = a_person(session, "Ah Meng")
            an_order(
                session,
                sold_by=who,
                estimate_total_sen=59800,
                final_sen=55200,
            )
            session.commit()

            (row,) = variance_by_salesperson(session).rows

            assert row.name == "Ah Meng"
            assert row.variance_sen == -4600
            assert row.orders_priced == 1

    def test_an_order_priced_above_its_estimate_is_counted_not_averaged(
        self, db
    ) -> None:
        # §8.5: after site measurement the price will be the same or lower,
        # never higher. One of these is a broken promise, and netting it off
        # against the orders that behaved hides the only thing worth seeing.
        with db() as session:
            who = a_person(session, "Ah Meng")
            an_order(
                session,
                sold_by=who,
                estimate_total_sen=59800,
                final_sen=40000,
            )
            an_order(
                session,
                sold_by=who,
                estimate_total_sen=50000,
                final_sen=60000,
            )
            session.commit()

            (row,) = variance_by_salesperson(session).rows

            assert row.orders_over_estimate == 1
            # The net is still reported, and it is still negative. The count is
            # what stops that hiding the second order.
            assert row.variance_sen == -9800

    def test_a_final_equal_to_the_estimate_is_not_a_broken_promise(self, db) -> None:
        # §8.5 promises "the same or lower, never higher". Exactly the same is
        # the promise kept, and counting it as a breach would make every
        # supply-only job -- where there is nothing to measure and the final
        # lands on the estimate -- look like a fault.
        with db() as session:
            who = a_person(session, "Ah Meng")
            an_order(session, sold_by=who, estimate_total_sen=55200, final_sen=55200)
            session.commit()

            (row,) = variance_by_salesperson(session).rows

            assert row.orders_over_estimate == 0
            assert row.variance_sen == 0

    def test_one_sen_over_is_a_broken_promise(self, db) -> None:
        with db() as session:
            who = a_person(session, "Ah Meng")
            an_order(session, sold_by=who, estimate_total_sen=55200, final_sen=55201)
            session.commit()

            (row,) = variance_by_salesperson(session).rows

            assert row.orders_over_estimate == 1

    def test_each_salesperson_is_their_own_row(self, db) -> None:
        with db() as session:
            one = a_person(session, "Ah Meng")
            two = a_person(session, "Siti")
            an_order(session, sold_by=one, final_sen=50000)
            an_order(session, sold_by=two, final_sen=50000)
            session.commit()

            rows = variance_by_salesperson(session).rows

            assert {row.name for row in rows} == {"Ah Meng", "Siti"}

    def test_an_order_with_no_salesperson_is_still_reported(self, db) -> None:
        # Dropping it would make the report disagree with the order board about
        # how many orders exist, and somebody would trust the wrong one.
        with db() as session:
            an_order(session, final_sen=50000)
            session.commit()

            (row,) = variance_by_salesperson(session).rows

            assert row.user_id is None
            assert row.orders_priced == 1

    def test_a_cancelled_order_is_not_a_guess_worth_grading(self, db) -> None:
        with db() as session:
            who = a_person(session, "Ah Meng")
            order_id = an_order(session, sold_by=who, final_sen=50000)
            session.get(Order, order_id).status = "cancelled"
            session.commit()

            assert variance_by_salesperson(session).rows == []


class TestFairPerformance:
    def _cards(self, session: Session) -> None:
        publish_card(session, list_id="fair", payload=FAIR)
        publish_card(session, list_id="standard", payload=STANDARD)

    def test_a_fair_is_identified_by_the_promo_its_orders_pinned(self, db) -> None:
        with db() as session:
            self._cards(session)
            an_order(session, pinned_rate_card_version=1)
            session.commit()

            (fair,) = fair_performance(session).fairs

            assert fair.promo_code == FAIR["promo"]["code"]
            assert fair.valid_from == FAIR["promo"]["valid_from"]
            assert fair.orders == 1
            assert fair.estimate_total_sen == 55200
            assert fair.deposits_taken_sen == 30000

    def test_a_showroom_order_is_not_a_fair(self, db) -> None:
        with db() as session:
            self._cards(session)
            an_order(session, channel="showroom")
            session.commit()

            assert fair_performance(session).fairs == []

    def test_holds_opened_are_counted_against_their_fair(self, db) -> None:
        # §6.1: the RM300 is the fair's whole point, and a fair report without
        # it says how much was quoted but not how much was secured.
        with db() as session:
            self._cards(session)
            an_order(session, pinned_rate_card_version=1)
            push_category_lock(
                session,
                CategoryLockIn(
                    id=str(uuid.uuid4()),
                    customer_key="phone:0123456789",
                    category="curtain",
                    held_rate_card_version=1,
                    held_until=CONFIRMED + timedelta(days=365),
                    opened_at=CONFIRMED,
                ),
            )
            session.commit()

            (fair,) = fair_performance(session).fairs

            assert fair.locks_opened == 1

    def test_a_cancelled_order_leaves_the_fair_total(self, db) -> None:
        with db() as session:
            self._cards(session)
            order_id = an_order(session)
            session.get(Order, order_id).status = "cancelled"
            session.commit()

            assert fair_performance(session).fairs == []

    def test_a_fair_order_on_a_card_with_no_promo_is_its_own_row(self, db) -> None:
        # It is a real order. Hiding it would make the report disagree with the
        # order board.
        with db() as session:
            publish_card(session, list_id="standard", payload=STANDARD)
            an_order(session, pinned_rate_card_version=1)
            session.commit()

            (fair,) = fair_performance(session).fairs

            assert fair.promo_code is None
            assert fair.orders == 1


class TestOutstandingBalances:
    def test_a_balance_is_the_total_less_what_was_paid(self, db) -> None:
        with db() as session:
            an_order(session, estimate_total_sen=55200, deposit_paid_sen=30000)
            session.commit()

            report = outstanding_balances(session, now=NOW)

            (row,) = report.balances
            assert row.balance_sen == 25200
            assert report.total_balance_sen == 25200

    def test_an_estimated_balance_says_it_is_an_estimate(self, db) -> None:
        # §8.5 makes a quotation an upper bound: the final will be the same or
        # lower, never higher. So this is the most that could be owed, not a
        # debt, and a report that did not say so would overstate the book.
        with db() as session:
            an_order(session)
            session.commit()

            report = outstanding_balances(session, now=NOW)

            assert report.balances[0].is_estimate is True
            assert report.estimated_balance_sen == report.total_balance_sen

    def test_a_final_price_replaces_the_estimate(self, db) -> None:
        with db() as session:
            an_order(
                session,
                estimate_total_sen=59800,
                deposit_paid_sen=30000,
                final_sen=55200,
            )
            session.commit()

            report = outstanding_balances(session, now=NOW)

            (row,) = report.balances
            assert row.total_sen == 55200
            assert row.balance_sen == 25200
            assert row.is_estimate is False
            assert report.estimated_balance_sen == 0

    def test_a_fully_paid_order_is_not_outstanding(self, db) -> None:
        with db() as session:
            an_order(session, estimate_total_sen=55200, deposit_paid_sen=55200)
            session.commit()

            assert outstanding_balances(session, now=NOW).balances == []

    def test_an_overpaid_order_is_not_reported_as_a_negative(self, db) -> None:
        # What to do about the difference is a refund question, and this report
        # does not answer money questions.
        with db() as session:
            an_order(session, estimate_total_sen=30000, deposit_paid_sen=55200)
            session.commit()

            report = outstanding_balances(session, now=NOW)

            assert report.balances == []
            assert report.total_balance_sen == 0

    @pytest.mark.parametrize("status", ["closed", "cancelled"])
    def test_a_finished_order_owes_nothing(self, db, status) -> None:
        # `cancelled` especially: what happens to its deposit is §13 B3,
        # unanswered, so reporting a balance would be answering it.
        with db() as session:
            order_id = an_order(session)
            session.get(Order, order_id).status = status
            session.commit()

            assert outstanding_balances(session, now=NOW).balances == []

    def test_the_oldest_deposit_is_at_the_top(self, db) -> None:
        with db() as session:
            an_order(
                session, customer_name="Recent", confirmed_at=NOW - timedelta(days=2)
            )
            an_order(
                session, customer_name="Old", confirmed_at=NOW - timedelta(days=200)
            )
            session.commit()

            report = outstanding_balances(session, now=NOW)

            assert [row.customer_name for row in report.balances] == ["Old", "Recent"]

    def test_the_buckets_are_half_open_so_a_row_lands_in_exactly_one(self, db) -> None:
        with db() as session:
            for days in (0, 30, 31, 60, 61, 90, 91, 400):
                an_order(session, confirmed_at=NOW - timedelta(days=days))
            session.commit()

            report = outstanding_balances(session, now=NOW)

            counts = {b.label: b.orders for b in report.buckets}
            assert counts == {
                "0-30 days": 2,
                "31-60 days": 2,
                "61-90 days": 2,
                "Over 90 days": 2,
            }
            assert sum(counts.values()) == len(report.balances)

    def test_the_buckets_add_up_to_the_total(self, db) -> None:
        with db() as session:
            for days in (5, 45, 75, 300):
                an_order(session, confirmed_at=NOW - timedelta(days=days))
            session.commit()

            report = outstanding_balances(session, now=NOW)

            assert (
                sum(b.balance_sen for b in report.buckets) == report.total_balance_sen
            )

    def test_every_bucket_is_present_even_when_empty(self, db) -> None:
        # A quiet month must not silently drop a column and make the report a
        # different shape from last month's.
        with db() as session:
            an_order(session, confirmed_at=NOW)
            session.commit()

            report = outstanding_balances(session, now=NOW)

            assert len(report.buckets) == 4

    def test_a_handset_clock_ahead_of_the_server_never_ages_backwards(self, db) -> None:
        with db() as session:
            an_order(session, confirmed_at=NOW + timedelta(days=3))
            session.commit()

            (row,) = outstanding_balances(session, now=NOW).balances

            assert row.days_since_deposit == 0

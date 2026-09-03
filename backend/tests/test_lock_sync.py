"""Rate locks reaching the server, and coming back. SPEC.md §6.1, §9.2.

A hold that lives only on the handset that took the deposit is one handset's
secret. Six phones work a fair; the customer deposits on phone 3 and walks into
the showroom in March where phone 1 is used. Without these endpoints that
customer is quoted the standard rate — more than the hold they paid for.

The case worth the most attention is two handsets each taking a deposit for the
same category before either syncs. Both payments are real money, and §13 B10 is
where what happens to the second RM300 gets decided. What must never happen is
that either row quietly disappears.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import CategoryLockIn, DepositPromptIn
from app.models.db import Base, CategoryLock, DepositPrompt, User
from app.services.ingest import (
    locks_for_customer,
    push_category_lock,
    push_deposit_prompt,
)

AT_THE_FAIR = datetime(2026, 8, 29, 14, 0, tzinfo=UTC)
HELD_UNTIL = datetime(2027, 8, 29, 0, 0, tzinfo=UTC)


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


def a_lock(**over) -> CategoryLockIn:
    fields = {
        "id": str(uuid.uuid4()),
        "customer_key": "phone:0123456789",
        "category": "curtain",
        "held_rate_card_version": 1,
        "held_discount_pct": "1/10",
        "held_until": HELD_UNTIL,
        "opened_at": AT_THE_FAIR,
    }
    fields.update(over)
    return CategoryLockIn(**fields)


class TestAHoldReachesTheServer:
    def test_it_is_stored_with_both_pinned_numbers(self, db) -> None:
        # §6.1: pinning only the version silently reprices this customer when
        # the promo percentage moves.
        payload = a_lock()
        with db() as session:
            result = push_category_lock(session, payload)
            session.commit()

        assert result.duplicate is False
        assert result.conflicts_with is None

        with db() as session:
            lock = session.get(CategoryLock, payload.id)
            assert lock is not None
            assert lock.held_rate_card_version == 1
            assert lock.held_discount_pct == "1/10"
            assert lock.status == "active"

    def test_a_retry_does_not_open_a_second_hold(self, db) -> None:
        # The RM300 was taken before the row existed. A dropped connection must
        # not turn one deposit into two holds.
        payload = a_lock()
        with db() as session:
            first = push_category_lock(session, payload)
            session.commit()
        with db() as session:
            second = push_category_lock(session, payload)
            session.commit()

        assert first.duplicate is False
        assert second.duplicate is True
        with db() as session:
            assert len(session.scalars(select(CategoryLock)).all()) == 1

    def test_it_records_who_opened_it(self, db) -> None:
        payload = a_lock()
        with db() as session:
            user = User(id=str(uuid.uuid4()), name="Ah Lian", role="parttime")
            session.add(user)
            session.flush()
            push_category_lock(session, payload, opened_by=user)
            session.commit()
            assert session.get(CategoryLock, payload.id).opened_by_user_id == user.id

    def test_the_server_does_not_re_decide_whether_it_was_allowed(self, db) -> None:
        # The device already refused outside a fair and below the minimum, at
        # the moment the money changed hands. Refusing it now would leave a
        # customer who has paid RM300 holding nothing.
        payload = a_lock(held_discount_pct="0")
        with db() as session:
            assert push_category_lock(session, payload).duplicate is False
            session.commit()
            assert session.get(CategoryLock, payload.id) is not None


class TestTwoHandsetsOneCategory:
    def test_both_rows_survive_and_the_first_keeps_pricing(self, db) -> None:
        # §13 B10. Two part-timers each take a curtain deposit from the same
        # customer before either syncs. Both payments are real; what must never
        # happen is that either row quietly disappears.
        first = a_lock()
        second = a_lock()

        with db() as session:
            push_category_lock(session, first)
            session.commit()
            result = push_category_lock(session, second)
            session.commit()

        assert result.duplicate is False
        assert (
            result.conflicts_with == first.id
        ), "the handset that sent it has to be told, so somebody can act"

        with db() as session:
            rows = {row.id: row for row in session.scalars(select(CategoryLock))}
            assert len(rows) == 2, "neither payment is lost"
            assert rows[first.id].status == "active"
            assert rows[second.id].status == "superseded"

            held = locks_for_customer(session, "phone:0123456789")
            assert [lock.id for lock in held] == [
                first.id
            ], "one active hold per customer and category, per §6.1"

    def test_a_different_category_is_not_a_conflict(self, db) -> None:
        # Curtain and flooring are two RM300s on purpose. §13 B1.
        curtain = a_lock(category="curtain")
        flooring = a_lock(category="flooring")

        with db() as session:
            push_category_lock(session, curtain)
            result = push_category_lock(session, flooring)
            session.commit()

            assert result.conflicts_with is None
            assert len(locks_for_customer(session, "phone:0123456789")) == 2

    def test_a_different_customer_is_not_a_conflict(self, db) -> None:
        with db() as session:
            push_category_lock(session, a_lock(customer_key="phone:0123456789"))
            result = push_category_lock(
                session, a_lock(customer_key="phone:0129999999")
            )
            session.commit()
            assert result.conflicts_with is None

    def test_a_cancelled_hold_does_not_block_a_new_one(self, db) -> None:
        # A refunded deposit should not stop the customer buying another hold.
        with db() as session:
            push_category_lock(session, a_lock(status="cancelled"))
            result = push_category_lock(session, a_lock())
            session.commit()

            assert result.conflicts_with is None
            assert len(locks_for_customer(session, "phone:0123456789")) == 1


class TestReadingHoldsBack:
    def test_a_second_handset_can_see_the_hold(self, db) -> None:
        # The whole point. Phone 3 took the deposit; phone 1 asks in March.
        with db() as session:
            push_category_lock(session, a_lock())
            session.commit()

            held = locks_for_customer(session, "phone:0123456789")
            assert len(held) == 1
            assert held[0].held_discount_pct == "1/10"

    def test_another_customer_sees_nothing(self, db) -> None:
        with db() as session:
            push_category_lock(session, a_lock())
            session.commit()
            assert locks_for_customer(session, "phone:0129999999") == []

    def test_expiry_is_left_to_the_resolver(self, db) -> None:
        # A handset offline for a week needs the row to judge for itself. The
        # server filtering on today's date would hide a hold from a device
        # pricing a quote taken yesterday.
        stale = a_lock(held_until=datetime(2020, 1, 1, tzinfo=UTC))
        with db() as session:
            push_category_lock(session, stale)
            session.commit()
            assert len(locks_for_customer(session, "phone:0123456789")) == 1

    def test_a_superseded_hold_is_not_handed_out(self, db) -> None:
        with db() as session:
            push_category_lock(session, a_lock())
            push_category_lock(session, a_lock())
            session.commit()
            assert len(locks_for_customer(session, "phone:0123456789")) == 1


class TestTheDepositPromptLog:
    def test_every_answer_is_stored(self, db) -> None:
        # The declined-deposit report only tells the boss what fairs are
        # leaving on the table if a decline arrives as reliably as a sale.
        for choice in ("collected", "declined", "lines_removed", "dismissed"):
            payload = DepositPromptIn(
                id=str(uuid.uuid4()),
                quote_id=str(uuid.uuid4()),
                category="curtain",
                choice=choice,
                category_subtotal_sen=55200,
                at=AT_THE_FAIR,
            )
            with db() as session:
                push_deposit_prompt(session, payload)
                session.commit()

        with db() as session:
            stored = {row.choice for row in session.scalars(select(DepositPrompt))}
            assert stored == {"collected", "declined", "lines_removed", "dismissed"}

    def test_a_retry_does_not_double_count_a_decline(self, db) -> None:
        payload = DepositPromptIn(
            id=str(uuid.uuid4()),
            quote_id=str(uuid.uuid4()),
            category="curtain",
            choice="declined",
            category_subtotal_sen=55200,
            at=AT_THE_FAIR,
        )
        with db() as session:
            assert push_deposit_prompt(session, payload).duplicate is False
            session.commit()
        with db() as session:
            assert push_deposit_prompt(session, payload).duplicate is True
            session.commit()
            assert len(session.scalars(select(DepositPrompt)).all()) == 1

    def test_the_subtotal_travels_with_it(self, db) -> None:
        # Without it the report can only say how often somebody said no, not
        # what it cost.
        payload = DepositPromptIn(
            id=str(uuid.uuid4()),
            quote_id=str(uuid.uuid4()),
            category="flooring",
            choice="declined",
            category_subtotal_sen=88800,
            at=AT_THE_FAIR,
        )
        with db() as session:
            push_deposit_prompt(session, payload)
            session.commit()
            assert session.get(DepositPrompt, payload.id).category_subtotal_sen == 88800

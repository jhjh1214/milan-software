"""The order board at 500 orders. SPEC.md §11 Phase 5.

    Order board loads 500 orders without pagination lag

The acceptance criterion, and the one that needs a populated database to mean
anything. What is asserted is not a wall-clock number -- a timing assertion in
CI fails on a busy runner and gets loosened until it means nothing -- but the
thing that actually causes the lag:

**The number of SQL statements does not grow with the number of orders.**

That is the failure mode this design invites. The board's `held_until` comes
from another table keyed on a string `orders` does not hold, so the obvious
simplification is a lookup per card, and the obvious simplification is a query
per card. Five hundred cards then means five hundred round trips, and the one
screen the office lives in becomes the one they stop opening. A constant here
is what stops that, and it is checked at ten orders and again at five hundred so
a regression cannot hide inside a plausible-looking number.

The rows each statement touches are bounded too: every one is scoped to the
orders on the page rather than to the table, so the work grows with the screen
and not with the business.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import CategoryLockIn, OrderIn, OrderLineIn
from app.models.db import Base
from app.services.ingest import push_category_lock, push_order
from app.services.reads import list_orders

CONFIRMED = datetime(2026, 8, 10, 14, 0, tzinfo=UTC)

#: §11 Phase 5's number. Not a round figure picked for a test.
BOARD_SIZE = 500


@pytest.fixture
def db() -> Iterator[tuple[sessionmaker[Session], Engine]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False), engine
    engine.dispose()


class Counter:
    """Counts SQL statements while it is attached."""

    def __init__(self, engine: Engine) -> None:
        self.engine = engine
        self.statements: list[str] = []

    def __enter__(self) -> Counter:
        event.listen(self.engine, "before_cursor_execute", self._record)
        return self

    def __exit__(self, *_: object) -> None:
        event.remove(self.engine, "before_cursor_execute", self._record)

    def _record(self, conn, cursor, statement, parameters, context, many) -> None:  # noqa: ANN001
        self.statements.append(statement)

    def __len__(self) -> int:
        return len(self.statements)


def seed(session: Session, count: int, *, with_holds: bool = True) -> None:
    """`count` orders, each with lines, and a hold for every third customer.

    Every order gets a distinct phone, so the customer-key lookup has as many
    distinct keys as there are cards -- which is the shape that would make a
    per-card query most tempting and most expensive.
    """
    for n in range(count):
        phone = f"01{n:08d}"
        order_id = str(uuid.uuid4())
        push_order(
            session,
            OrderIn(
                id=order_id,
                quote_id=str(uuid.uuid4()),
                channel="fair" if n % 2 else "showroom",
                pinned_rate_card_version=1,
                customer_name=f"Customer {n}",
                customer_phone=phone,
                estimate_total_sen=55200,
                deposit_paid_sen=30000,
                confirmed_at=CONFIRMED - timedelta(hours=n),
                lines=[
                    OrderLineIn(
                        id=str(uuid.uuid4()),
                        quote_line_id=str(uuid.uuid4()),
                        sort_order=i,
                        room=f"Room {i}",
                        variant="night_curtain_sfold",
                        layer="night",
                        est_width_tmm=36576,
                        applied_rule_id="rule-1",
                        applied_rate_card_version=1,
                        standard_rate_sen=4600,
                        rate_sen=4600,
                        billed_qty="12",
                        billed_unit="ft",
                        line_total_sen=55200,
                    )
                    for i in range(3)
                ],
            ),
        )

        if with_holds and n % 3 == 0:
            push_category_lock(
                session,
                CategoryLockIn(
                    id=str(uuid.uuid4()),
                    customer_key=f"phone:{phone}",
                    category="curtain",
                    held_rate_card_version=1,
                    held_until=CONFIRMED + timedelta(days=365 - n),
                    opened_at=CONFIRMED,
                ),
            )
    session.commit()


class TestFiveHundredOrders:
    def test_the_board_returns_all_of_them_with_a_true_total(self, db) -> None:
        factory, _ = db
        with factory() as session:
            seed(session, BOARD_SIZE)

            orders, total = list_orders(session)

            assert total == BOARD_SIZE
            assert len(orders) == BOARD_SIZE
            # Every card, not just the first. Scoping the count query to the
            # page is only safe if the scope is the whole page.
            assert all(o.line_count == 3 for o in orders)

    def test_the_statement_count_does_not_grow_with_the_board(self, db) -> None:
        # The whole criterion, expressed as the thing that would break it. Ten
        # orders and five hundred must cost the same number of round trips; a
        # lookup per card would make the second five hundred.
        factory, engine = db
        with factory() as session:
            seed(session, 10)
            with Counter(engine) as small:
                list_orders(session)

        factory2, engine2 = db
        del factory2, engine2

        with factory() as session:
            seed(session, BOARD_SIZE - 10)
            with Counter(engine) as large:
                orders, total = list_orders(session)

        assert total == BOARD_SIZE
        assert len(orders) == BOARD_SIZE
        assert len(large) == len(
            small
        ), f"{len(small)} statements for 10 orders, {len(large)} for {BOARD_SIZE}"

    def test_the_holds_still_sort_and_colour_correctly_at_that_size(self, db) -> None:
        # Scoping the lock query to the page is only safe if it still finds
        # every hold on it. §11: a hold that runs out unused is a customer who
        # paid RM300 and got nothing, so a missed one is the expensive miss.
        factory, _ = db
        with factory() as session:
            seed(session, BOARD_SIZE)

            orders, _ = list_orders(session)

            with_holds = [o for o in orders if o.held_until is not None]
            assert len(with_holds) == len(range(0, BOARD_SIZE, 3))

            # Sorted ascending, nulls last.
            assert orders[0].held_until is not None
            assert orders[-1].held_until is None
            expiries = [o.held_until for o in with_holds]
            assert expiries == sorted(expiries)

    def test_a_filter_narrows_the_page_and_the_total_with_it(self, db) -> None:
        factory, _ = db
        with factory() as session:
            seed(session, BOARD_SIZE)

            orders, total = list_orders(session, channel="fair")

            assert total == BOARD_SIZE // 2
            assert len(orders) == BOARD_SIZE // 2
            assert all(o.channel == "fair" for o in orders)

    def test_a_filtered_page_costs_no_more_statements(self, db) -> None:
        factory, engine = db
        with factory() as session:
            seed(session, BOARD_SIZE)

            with Counter(engine) as unfiltered:
                list_orders(session)
            with Counter(engine) as filtered:
                list_orders(session, channel="fair")

            assert len(filtered) == len(unfiltered)

    def test_a_page_of_fifty_out_of_five_hundred(self, db) -> None:
        factory, _ = db
        with factory() as session:
            seed(session, BOARD_SIZE)

            orders, total = list_orders(session, limit=50)

            # The board can say "50 of 500", which is what stops somebody
            # guessing whether their filter did anything.
            assert len(orders) == 50
            assert total == BOARD_SIZE

    def test_an_empty_board_asks_for_nothing_it_cannot_use(self, db) -> None:
        # With no orders there are no ids and no customer keys, so the scoped
        # queries have nothing to scope to. They must not run at all, let alone
        # unscoped: a board showing nothing should not be reading every hold
        # and every line in the business to work that out.
        factory, engine = db
        with factory() as session:
            seed(session, 5)
            # Filtered to nothing, so the table is full and the page is empty.
            with Counter(engine) as counter:
                orders, total = list_orders(session, status="closed")

            assert orders == []
            assert total == 0

            touched = " ".join(counter.statements).lower()
            assert "category_locks" not in touched
            assert "order_lines" not in touched

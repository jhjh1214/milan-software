"""What the dashboard reads. SPEC.md §11 Phase 5.

Every other endpoint in this service is a push, and that asymmetry is why two
rate lock bugs went unnoticed: nothing ever read the data back.

The two things worth the most attention here are the ordering — the board sorts
by how soon a hold runs out, because a hold that expires unused is a customer
who paid RM300 and got nothing — and the customer key, which has to be built the
same way the device builds it or the board silently shows no expiry for
everybody who typed their phone with a dash in it.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.schemas import CategoryLockIn, OrderIn, OrderLineIn, PriceOverrideIn
from app.models.db import Base
from app.services.ingest import push_category_lock, push_order
from app.services.reads import (
    list_orders,
    order_detail,
    overrides_between,
    prompts_between,
)

CONFIRMED = datetime(2026, 8, 29, 14, 0, tzinfo=UTC)


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


def a_hold(session: Session, *, phone: str, until: datetime, category="curtain"):
    push_category_lock(
        session,
        CategoryLockIn(
            id=str(uuid.uuid4()),
            customer_key=f"phone:{phone}",
            category=category,
            held_rate_card_version=1,
            held_until=until,
            opened_at=CONFIRMED,
        ),
    )


class TestTheBoard:
    def test_a_card_carries_what_the_board_shows(self, db) -> None:
        with db() as session:
            payload = an_order(session, customer_name="Ah Lian")
            session.commit()

            (card,), total = list_orders(session)
            assert total == 1
            assert card.id == payload.id
            assert card.order_no == "MLK-2608-0001"
            assert card.customer_name == "Ah Lian"
            assert card.estimate_total_sen == 55200
            assert card.line_count == 1

    def test_it_does_not_carry_the_lines(self, db) -> None:
        # The board shows 500 of these. Sending every line with each would make
        # the one screen the office lives in slow enough that people stop
        # opening it.
        with db() as session:
            an_order(session, lines=[a_line(), a_line(sort_order=1)])
            session.commit()
            (card,), _ = list_orders(session)
            assert card.line_count == 2
            assert not hasattr(card, "lines")

    def test_the_total_is_what_matches_not_what_is_returned(self, db) -> None:
        # A board that cannot say "2 of 5" leaves somebody guessing whether the
        # filter did anything.
        with db() as session:
            for _ in range(5):
                an_order(session)
            session.commit()

            page, total = list_orders(session, limit=2)
            assert len(page) == 2
            assert total == 5

    def test_offset_walks_the_board_without_repeating(self, db) -> None:
        with db() as session:
            for _ in range(5):
                an_order(session)
            session.commit()

            first, _ = list_orders(session, limit=2, offset=0)
            second, _ = list_orders(session, limit=2, offset=2)
            assert {o.id for o in first}.isdisjoint({o.id for o in second})


class TestFilters:
    def test_each_one_narrows(self, db) -> None:
        with db() as session:
            an_order(session, channel="fair")
            an_order(session, channel="showroom")
            session.commit()

            _, fair = list_orders(session, channel="fair")
            _, showroom = list_orders(session, channel="showroom")
            _, everything = list_orders(session)
            assert (fair, showroom, everything) == (1, 1, 2)

    def test_they_combine(self, db) -> None:
        with db() as session:
            an_order(session, channel="fair", status="measurement_booked")
            an_order(session, channel="fair")
            an_order(session, channel="showroom", status="measurement_booked")
            session.commit()

            _, total = list_orders(session, channel="fair", status="measurement_booked")
            assert total == 1

    def test_the_date_window_is_half_open(self, db) -> None:
        # One order lands in exactly one period rather than in two or neither,
        # the same as the weekly override review.
        monday = datetime(2026, 8, 24, tzinfo=UTC)
        next_monday = datetime(2026, 8, 31, tzinfo=UTC)

        with db() as session:
            an_order(session, confirmed_at=monday - timedelta(seconds=1))
            an_order(session, confirmed_at=monday)
            an_order(session, confirmed_at=next_monday - timedelta(seconds=1))
            an_order(session, confirmed_at=next_monday)
            session.commit()

            _, total = list_orders(
                session, confirmed_from=monday, confirmed_to=next_monday
            )
            assert total == 2

    def test_a_filter_matching_nothing_is_empty_not_everything(self, db) -> None:
        with db() as session:
            an_order(session, channel="fair")
            session.commit()
            page, total = list_orders(session, channel="phone")
            assert page == []
            assert total == 0


class TestHoldExpiry:
    def test_the_soonest_hold_is_on_the_card(self, db) -> None:
        soon = datetime(2027, 1, 1, tzinfo=UTC)
        later = datetime(2027, 8, 29, tzinfo=UTC)

        with db() as session:
            an_order(session, customer_phone="0123456789")
            a_hold(session, phone="0123456789", until=later)
            a_hold(session, phone="0123456789", until=soon, category="flooring")
            session.commit()

            (card,), _ = list_orders(session)
            # Compared naive: SQLite stores no offset, so a value that is
            # tz-aware on Postgres comes back without one here. The instant is
            # the same and it is the instant the board sorts on.
            assert card.held_until is not None
            assert card.held_until.replace(tzinfo=None) == soon.replace(
                tzinfo=None
            ), "the board colours by the one that runs out first"

    def test_the_key_is_built_the_way_the_device_builds_it(self, db) -> None:
        # The customer typed a dash. Looking them up by what they typed would
        # miss the hold they paid for -- the exact bug this area already had.
        with db() as session:
            an_order(session, customer_phone="012-345 6789")
            a_hold(
                session,
                phone="0123456789",
                until=datetime(2027, 8, 29, tzinfo=UTC),
            )
            session.commit()

            (card,), _ = list_orders(session)
            assert card.held_until is not None

    def test_an_order_with_no_phone_has_no_expiry(self, db) -> None:
        with db() as session:
            an_order(session)
            a_hold(
                session,
                phone="0123456789",
                until=datetime(2027, 8, 29, tzinfo=UTC),
            )
            session.commit()

            (card,), _ = list_orders(session)
            assert card.held_until is None

    def test_the_board_sorts_by_expiry_with_nothing_running_out_last(self, db) -> None:
        # §11 Phase 5. A hold that expires unused is a customer who paid RM300
        # and got nothing, so those cards belong at the top.
        with db() as session:
            an_order(session, customer_phone="0111111111")
            a_hold(
                session,
                phone="0111111111",
                until=datetime(2027, 6, 1, tzinfo=UTC),
            )
            an_order(session, customer_phone="0222222222")
            a_hold(
                session,
                phone="0222222222",
                until=datetime(2027, 1, 1, tzinfo=UTC),
            )
            an_order(session, customer_phone=None)
            session.commit()

            page, _ = list_orders(session)
            assert [card.customer_phone for card in page] == [
                "0222222222",
                "0111111111",
                None,
            ]

    def test_a_cancelled_hold_does_not_colour_the_card(self, db) -> None:
        with db() as session:
            an_order(session, customer_phone="0123456789")
            push_category_lock(
                session,
                CategoryLockIn(
                    id=str(uuid.uuid4()),
                    customer_key="phone:0123456789",
                    category="curtain",
                    held_rate_card_version=1,
                    held_until=datetime(2027, 1, 1, tzinfo=UTC),
                    status="cancelled",
                    opened_at=CONFIRMED,
                ),
            )
            session.commit()

            (card,), _ = list_orders(session)
            assert card.held_until is None


class TestOneOrder:
    def test_it_answers_the_whole_question_in_one_response(self, db) -> None:
        line = a_line()
        with db() as session:
            payload = an_order(
                session,
                lines=[line],
                overrides=[
                    PriceOverrideIn(
                        id=str(uuid.uuid4()),
                        order_line_id=line.id,
                        before_sen=55200,
                        after_sen=50000,
                        reason="matched a competitor quote",
                        admin_user_id="u-boss",
                        at=CONFIRMED,
                    )
                ],
            )
            session.commit()

            detail = order_detail(session, payload.id)
            assert detail is not None
            assert detail.order.id == payload.id
            assert len(detail.lines) == 1
            assert detail.lines[0].applied_rate_card_version == 1
            assert len(detail.overrides) == 1
            assert detail.overrides[0].reason == "matched a competitor quote"

    def test_an_unknown_order_is_none_not_an_empty_shell(self, db) -> None:
        # An empty detail would render as an order with no lines, which reads
        # as a real order that lost its contents.
        with db() as session:
            assert order_detail(session, str(uuid.uuid4())) is None


class TestTheReviewQueries:
    def test_overrides_come_back_newest_first_in_a_half_open_window(self, db) -> None:
        monday = datetime(2026, 8, 24, tzinfo=UTC)
        next_monday = datetime(2026, 8, 31, tzinfo=UTC)
        line = a_line()
        ids = [str(uuid.uuid4()) for _ in range(4)]

        with db() as session:
            an_order(
                session,
                lines=[line],
                overrides=[
                    PriceOverrideIn(
                        id=ids[i],
                        order_line_id=line.id,
                        before_sen=55200,
                        after_sen=55200 - i - 1,
                        reason=f"reason {i}",
                        admin_user_id="u-boss",
                        at=at,
                    )
                    for i, at in enumerate(
                        [
                            monday - timedelta(seconds=1),
                            monday,
                            datetime(2026, 8, 27, tzinfo=UTC),
                            next_monday,
                        ]
                    )
                ],
            )
            session.commit()

            rows = overrides_between(session, start=monday, end=next_monday)
            # The Wednesday one first, then the Monday: newest first, with the
            # Sunday before and the next Monday both outside the window.
            assert [row.id for row in rows] == [ids[2], ids[1]]

    def test_prompts_come_back_raw_rather_than_summarised(self, db) -> None:
        # The dashboard will slice these by salesperson and by fair.
        # Aggregating here would mean two summaries that have to agree and
        # eventually will not.
        from app.api.schemas import DepositPromptIn
        from app.services.ingest import push_deposit_prompt

        with db() as session:
            for choice in ("collected", "declined"):
                push_deposit_prompt(
                    session,
                    DepositPromptIn(
                        id=str(uuid.uuid4()),
                        quote_id=str(uuid.uuid4()),
                        category="curtain",
                        choice=choice,
                        category_subtotal_sen=55200,
                        at=CONFIRMED,
                    ),
                )
            session.commit()

            rows = prompts_between(
                session,
                start=datetime(2026, 8, 1, tzinfo=UTC),
                end=datetime(2026, 9, 1, tzinfo=UTC),
            )
            assert {row.choice for row in rows} == {"collected", "declined"}
            assert all(row.category_subtotal_sen == 55200 for row in rows)

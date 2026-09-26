"""The rate lock resolver, against the same cases the Dart suite loads.

SPEC.md §6.1 asks for these before the resolver. The one that matters most:

    Silently applying a curtain lock to a flooring line is the expensive bug in
    this design.

If this file and ``mobile/test/pricing/rate_lock_test.dart`` ever disagree, one
of the two engines is charging a customer the wrong price -- which is exactly
what CLAUDE.md hard rule 3 puts the fixture file there to prevent.
"""

from __future__ import annotations

import json
from datetime import date
from fractions import Fraction
from pathlib import Path

import pytest

from app.pricing.models import (
    DepositCategory,
    Family,
    UnknownDepositCategory,
    deposit_category_of,
)
from app.pricing.rate_lock import (
    CategoryLock,
    Channel,
    LockRefusal,
    LockStatus,
    open_category_lock,
    resolve_rate_basis,
    twelve_months_from,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads(
    (ROOT / "shared" / "pricing-fixtures.json").read_text(encoding="utf-8")
)
CASES = FIXTURES["rate_lock_cases"]
GRANT_CASES = FIXTURES["lock_grant_cases"]


def a_lock(raw: dict) -> CategoryLock:
    return CategoryLock(
        id=raw["id"],
        category=DepositCategory(raw["category"]),
        held_rate_card_version=raw["held_rate_card_version"],
        held_discount_pct=Fraction(raw["held_discount_pct"]),
        held_until=date.fromisoformat(raw["held_until"]),
        status=LockStatus(raw["status"]),
    )


def test_the_contract_carries_cases_at_all() -> None:
    # A fixture file that silently lost its cases would turn this whole module
    # green while testing nothing.
    assert len(CASES) >= 20


def test_every_branch_of_6_1_is_covered() -> None:
    # Three cases, and the spec says do not collapse them.
    assert {c["expect"]["basis"] for c in CASES} == {
        "held",
        "fair_current",
        "standard_pinned",
    }


@pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
def test_the_fixtures_agree_with_the_resolver(case: dict) -> None:
    line = case["line"]
    expected = case["expect"]

    basis = resolve_rate_basis(
        family=Family(line["family"]),
        deposit_category_override=(
            DepositCategory(line["deposit_category_override"])
            if line["deposit_category_override"]
            else None
        ),
        parent_family=(
            Family(line["parent_family"]) if line["parent_family"] else None
        ),
        locks=[a_lock(raw) for raw in case["locks"]],
        channel=Channel(case["channel"]),
        current_rate_card_version=case["current_rate_card_version"],
        current_promo_pct=Fraction(case["current_promo_pct"]),
        order_pinned_rate_card_version=case["order_pinned_rate_card_version"],
        today=date.fromisoformat(case["today"]),
    )

    why = case["why"]
    assert basis.source.value == expected["basis"], why
    assert basis.rate_card_version == expected["rate_card_version"], why
    assert str(basis.discount_pct) == expected["discount_pct"], why
    assert basis.lock_id == expected["lock_id"], why


class TestTheCasesTheFixturesCannotExpress:
    def test_an_addon_with_no_parent_is_refused(self) -> None:
        # A guess about money. Defaulting to curtains could price a motor at a
        # held curtain rate that its RM300 never bought.
        with pytest.raises(UnknownDepositCategory):
            deposit_category_of(Family.ADDON)

    def test_an_addon_hanging_off_an_addon_is_refused(self) -> None:
        with pytest.raises(UnknownDepositCategory):
            deposit_category_of(Family.ADDON, parent_family=Family.SERVICE)

    def test_a_lock_is_checked_by_status_and_by_date(self) -> None:
        # The nightly job that flips active to expired may not have run, so the
        # date is checked here too rather than trusted from the row.
        stale = CategoryLock(
            id="l",
            category=DepositCategory.CURTAIN,
            held_rate_card_version=1,
            held_discount_pct=Fraction(0),
            held_until=date(2027, 8, 29),
            status=LockStatus.ACTIVE,
        )
        assert stale.is_active_on(date(2027, 8, 29))
        assert not stale.is_active_on(date(2027, 8, 30))

    def test_a_cancelled_lock_inside_its_dates_is_still_not_a_price(
        self,
    ) -> None:
        cancelled = CategoryLock(
            id="l",
            category=DepositCategory.CURTAIN,
            held_rate_card_version=1,
            held_discount_pct=Fraction(0),
            held_until=date(2027, 8, 29),
            status=LockStatus.CANCELLED,
        )
        assert not cancelled.is_active_on(date(2027, 1, 1))


def test_the_contract_carries_grant_cases_too() -> None:
    assert len(GRANT_CASES) >= 12
    # Both outcomes, or the file is only testing one branch.
    assert {c["expect"]["granted"] for c in GRANT_CASES} == {True, False}


@pytest.mark.parametrize("case", GRANT_CASES, ids=[c["id"] for c in GRANT_CASES])
def test_the_fixtures_agree_with_the_grant_rule(case: dict) -> None:
    expected = case["expect"]

    grant = open_category_lock(
        id="new-lock",
        channel=Channel(case["channel"]),
        category=DepositCategory(case["category"]),
        deposit_date=date.fromisoformat(case["deposit_date"]),
        fair_ends_on=(
            date.fromisoformat(case["fair_ends_on"]) if case["fair_ends_on"] else None
        ),
        deposit_sen=case["deposit_sen"],
        min_deposit_sen=case["min_deposit_sen"],
        rate_card_version=case["rate_card_version"],
        promo_pct=Fraction(case["promo_pct"]),
    )

    why = case["why"]
    assert grant.granted is expected["granted"], why
    if not expected["granted"]:
        assert grant.refused_because is LockRefusal(expected["refused_because"]), why
        return

    lock = grant.lock
    assert lock is not None
    assert lock.held_rate_card_version == expected["held_rate_card_version"], why
    assert str(lock.held_discount_pct) == expected["held_discount_pct"], why
    assert lock.held_until == date.fromisoformat(expected["held_until"]), why


class TestOnlyAFairCanLock:
    def test_every_other_channel_is_refused(self) -> None:
        # Named one by one rather than "not fair", so a channel added later
        # cannot default into locking.
        for channel in Channel:
            grant = open_category_lock(
                id="l",
                channel=channel,
                category=DepositCategory.CURTAIN,
                deposit_date=date(2026, 8, 29),
                fair_ends_on=date(2026, 8, 31),
                deposit_sen=30000,
                min_deposit_sen=30000,
                rate_card_version=1,
                promo_pct=Fraction(0),
            )
            assert grant.granted is (channel is Channel.FAIR), channel

    def test_a_refused_grant_produces_no_row_at_all(self) -> None:
        # Not a lock with a flag on it. A row that exists can be read by
        # something that forgets to check the flag.
        grant = open_category_lock(
            id="l",
            channel=Channel.SHOWROOM,
            category=DepositCategory.CURTAIN,
            deposit_date=date(2026, 8, 29),
            fair_ends_on=date(2026, 8, 31),
            deposit_sen=30000,
            min_deposit_sen=30000,
            rate_card_version=1,
            promo_pct=Fraction(0),
        )
        assert grant.lock is None


class TestTwelveMonths:
    def test_a_leap_day_clamps_rather_than_rolling_forward(self) -> None:
        # Rolling forward would quietly extend the hold to 1 March.
        assert twelve_months_from(date(2028, 2, 29)) == date(2029, 2, 28)

    def test_a_month_end_that_exists_is_left_alone(self) -> None:
        assert twelve_months_from(date(2026, 8, 31)) == date(2027, 8, 31)
        assert twelve_months_from(date(2026, 1, 31)) == date(2027, 1, 31)

    def test_every_day_of_a_leap_year_lands_on_a_real_date(self) -> None:
        # A sweep rather than three examples: the clamp has to hold for all 366.
        day = date(2028, 1, 1)
        while day.year == 2028:
            held = twelve_months_from(day)
            assert held.year == 2029
            assert held.month == day.month
            assert held.day <= day.day
            day = date.fromordinal(day.toordinal() + 1)

    def test_the_hold_is_never_shortened_by_more_than_a_day(self) -> None:
        # The clamp exists for 29 February and nothing else. If it ever moved a
        # date by two days, something in the month lengths is wrong.
        day = date(2027, 1, 1)
        while day.year == 2027:
            assert (day.day - twelve_months_from(day).day) in (0, 1), day
            day = date.fromordinal(day.toordinal() + 1)


class TestPercentagesStayExact:
    def test_the_fixture_notation_round_trips(self) -> None:
        # The contract writes percentages as exact rationals. A float would put
        # a percentage of a price -- which is money -- into binary floating
        # point, and 1/3 cannot be written as a decimal at all.
        for text in ["0", "1", "1/10", "1/3", "-2/7", "5"]:
            assert str(Fraction(text)) == text

    def test_a_third_survives_where_a_decimal_would_not(self) -> None:
        assert Fraction("1/3") * 3 == 1

    def test_dart_and_python_spell_a_whole_number_the_same_way(self) -> None:
        # Dart's Rational.toString drops the denominator when it is one, and so
        # does Fraction. If either changed, every "0" in the fixtures would stop
        # matching on one side only.
        assert str(Fraction(0)) == "0"
        assert str(Fraction(20, 4)) == "5"

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
    LockStatus,
    resolve_rate_basis,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads(
    (ROOT / "shared" / "pricing-fixtures.json").read_text(encoding="utf-8")
)
CASES = FIXTURES["rate_lock_cases"]


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

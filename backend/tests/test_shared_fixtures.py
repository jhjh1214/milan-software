"""Runs `shared/pricing-fixtures.json` against the Python engine.

CLAUDE.md hard rule 3: that file is **the contract** between the Dart and Python
engines. Every case lives there once and both suites load it. A rule change
means editing the fixture, then making both sides pass.

This is the whole point of Phase 3's pricing work. §9.4 has the server re-price
every line the app sends; if the two engines disagree the customer is told one
number and invoiced another, and the discrepancy log fills up with noise nobody
can act on. These tests are what stops that.
"""

from __future__ import annotations

import json
from datetime import date
from fractions import Fraction
from pathlib import Path

import pytest

from app.core.length import Length
from app.core.money import Money
from app.pricing.engine import (
    LineRequest,
    PricedLine,
    price_line,
    total_quote,
)
from app.pricing.models import (
    CustomerTier,
    DepositCategory,
    Fulfilment,
    Layer,
    PricingStage,
    RateCard,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads(
    (ROOT / "shared" / "pricing-fixtures.json").read_text(encoding="utf-8")
)
CARD = RateCard.from_json(
    json.loads(
        (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
    )
)

STAGES = {"estimate": PricingStage.ESTIMATE, "final": PricingStage.FINAL}
TIERS = {"standard": CustomerTier.STANDARD, "mvp": CustomerTier.MVP}


def _fraction_str(value: Fraction) -> str:
    """Formats exactly as Dart's ``Rational.toString`` does."""
    return (
        str(value.numerator)
        if value.denominator == 1
        else f"{value.numerator}/{value.denominator}"
    )


@pytest.mark.parametrize(
    "case", FIXTURES["cases"], ids=[c["id"] for c in FIXTURES["cases"]]
)
def test_line_case(case: dict) -> None:
    line = case["line"]
    expected = case["expect"]

    result = price_line(
        request=LineRequest(
            variant=line["variant"],
            material_key=line["material_key"],
            layer=Layer(line["layer"]),
            fulfilment=Fulfilment(line["fulfilment"]),
            width=Length(line["width_tmm"]),
            height=None if line["height_tmm"] is None else Length(line["height_tmm"]),
            quantity=line["quantity"],
        ),
        card=CARD,
        stage=STAGES[case["stage"]],
        tier=TIERS[case["tier"]],
    )

    assert result.rule.id == expected["rule_id"], "wrong rule chosen"
    assert _fraction_str(result.billed_qty) == expected["billed_qty"]
    assert result.billed_unit == expected["billed_unit"]
    assert result.min_qty_applied == expected["min_qty_applied"]
    assert result.rate_sen == expected["rate_sen"], "wrong rate"
    assert result.total.sen == expected["total_sen"], (
        f"expected {Money(expected['total_sen'])}, got {result.total}"
    )

    if "material_deferred" in expected:
        assert result.material_deferred == expected["material_deferred"]
    if "material_options" in expected:
        assert list(result.material_options) == expected["material_options"]
    if "deposit_category" in expected:
        assert result.deposit_category.value == expected["deposit_category"], (
            "deposit category -- a lock on the wrong category misprices"
        )


def _stub_line(*, category: DepositCategory, total_sen: int) -> PricedLine:
    """A line carrying only a total and a category, for the order-level floor."""
    family = {
        DepositCategory.CURTAIN: "curtain",
        DepositCategory.FLOORING: "flooring",
        DepositCategory.WALLPAPER: "wallpaper",
    }[category]
    base = CARD.rules[0]
    stub = type(base)(
        id="stub",
        family=type(base.family)(family),
        variant=base.variant,
        layer=base.layer,
        material_key=None,
        fulfilment=base.fulfilment,
        labels=base.labels,
        basis=base.basis,
        band_field=type(base.band_field)("none"),
        band_min_tmm=None,
        band_max_tmm=None,
        band_labels=None,
        rate_sen=total_sen,
        mvp_rate_sen=None,
        min_qty=None,
        sort_order=0,
    )
    return PricedLine(
        rule=stub,
        stage=PricingStage.ESTIMATE,
        raw_qty=Fraction(1),
        billed_qty=Fraction(1),
        billed_unit="ft",
        min_qty_applied=False,
        standard_rate_sen=total_sen,
        rate_sen=total_sen,
        quantity=1,
        total=Money(total_sen),
    )


@pytest.mark.parametrize(
    "case",
    FIXTURES["quote_total_cases"],
    ids=[c["id"] for c in FIXTURES["quote_total_cases"]],
)
def test_quote_total_case(case: dict) -> None:
    totals = total_quote(
        lines=[
            _stub_line(category=DepositCategory(cat), total_sen=sen)
            for cat, sen in case["line_totals_sen"].items()
        ],
        card=CARD,
        stage=STAGES[case["stage"]],
        delivery_zone_id=case.get("delivery_zone_id"),
    )
    expected = case["expect"]

    for cat, sen in expected["category_subtotals_sen"].items():
        assert totals.category_subtotals[DepositCategory(cat)].sen == sen
    for cat, sen in expected["category_floor_uplift_sen"].items():
        assert totals.category_floor_uplift[DepositCategory(cat)].sen == sen
    if "delivery_charge_sen" in expected:
        assert totals.delivery_charge.sen == expected["delivery_charge_sen"]
    assert totals.total.sen == expected["total_sen"], "quote total"


def test_the_fixture_file_is_not_empty() -> None:
    # A green suite over an empty contract proves nothing.
    assert len(FIXTURES["cases"]) >= 20
    assert len(FIXTURES["quote_total_cases"]) >= 5


def test_the_card_is_the_real_price_list() -> None:
    assert CARD.provisional is False
    assert len(CARD.rules) == 77
    assert len(CARD.delivery_zones) == 2
    assert CARD.promo is not None
    assert CARD.promo.code == "MITC-2026-08"


def test_the_fair_card_expires_outside_its_window() -> None:
    assert CARD.is_expired_on(date(2026, 8, 29)) is False
    assert CARD.is_expired_on(date(2026, 8, 31)) is False
    assert CARD.is_expired_on(date(2026, 9, 1)) is True

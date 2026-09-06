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
from app.pricing.einvoice_threshold import (
    BuyerDetails,
    BuyerDetailsMissing,
    ThresholdConfig,
    ThresholdReason,
    ThresholdStage,
    buyer_details_complete,
    check_threshold,
    missing_buyer_details,
)
from app.pricing.engine import (
    LineRequest,
    PricedLine,
    price_line,
    total_quote,
)
from app.pricing.final_pricing import (
    FinalPricingRefusal,
    MeasuredLine,
    reprice_order,
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
    assert (
        result.total.sen == expected["total_sen"]
    ), f"expected {Money(expected['total_sen'])}, got {result.total}"

    if "material_deferred" in expected:
        assert result.material_deferred == expected["material_deferred"]
    if "material_options" in expected:
        assert list(result.material_options) == expected["material_options"]
    if "deposit_category" in expected:
        assert (
            result.deposit_category.value == expected["deposit_category"]
        ), "deposit category -- a lock on the wrong category misprices"


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


@pytest.mark.parametrize(
    "case",
    FIXTURES["final_pricing_cases"],
    ids=[c["id"] for c in FIXTURES["final_pricing_cases"]],
)
def test_final_pricing_case(case: dict) -> None:
    """SPEC.md §11 Phase 6. Repricing a measured order.

    ``available_card_versions`` decides which cards the caller holds. Only
    version 1 exists as a file, so a case that lists another version is saying
    the held card is not to hand -- which must refuse rather than fall back to
    the active one.
    """
    cards = {
        version: CARD
        for version in case["available_card_versions"]
        if version == CARD.version
    }

    result = reprice_order(
        lines=[
            MeasuredLine(
                id=line["id"],
                variant=line["variant"],
                material_key=line["material_key"],
                layer=Layer(line["layer"]),
                fulfilment=Fulfilment(line["fulfilment"]),
                quantity=line["quantity"],
                estimate_total=Money(line["estimate_total_sen"]),
                applied_rate_card_version=line["applied_rate_card_version"],
                final_width=(
                    None
                    if line["final_width_tmm"] is None
                    else Length(line["final_width_tmm"])
                ),
                final_height=(
                    None
                    if line["final_height_tmm"] is None
                    else Length(line["final_height_tmm"])
                ),
                material_deferred=line["material_deferred"],
            )
            for line in case["lines"]
        ],
        cards=cards,
    )

    expected = case["expect"]
    assert [line.id for line in result.lines] == [e["id"] for e in expected["lines"]]

    for got, want in zip(result.lines, expected["lines"], strict=True):
        assert got.priced_at_version == want["priced_at_version"], f"{got.id} version"
        assert (None if got.final_total is None else got.final_total.sen) == want[
            "final_total_sen"
        ], f"{got.id} total"
        assert (None if got.variance is None else got.variance.sen) == want[
            "variance_sen"
        ], f"{got.id} variance"
        assert got.is_over_estimate is want["over_estimate"], f"{got.id} over"
        assert (None if got.refusal is None else got.refusal.value) == want[
            "refusal"
        ], f"{got.id} refusal"

        if "billed_qty" in want:
            assert _fraction_str(got.billed_qty) == want["billed_qty"]
            assert got.priced is not None
            assert got.priced.billed_unit == want["billed_unit"]

    assert result.estimate_total.sen == expected["estimate_total_sen"]
    assert (None if result.final_total is None else result.final_total.sen) == expected[
        "final_total_sen"
    ]
    assert (None if result.variance is None else result.variance.sen) == expected[
        "variance_sen"
    ]
    assert result.is_complete is expected["is_complete"]


def test_every_refusal_reason_is_exercised() -> None:
    # A refusal nothing covers is a branch that will be wrong the first time it
    # fires, in a house, with a customer watching.
    seen = {
        line["refusal"]
        for case in FIXTURES["final_pricing_cases"]
        for line in case["expect"]["lines"]
        if line["refusal"] is not None
    }
    assert FinalPricingRefusal.NOT_MEASURED.value in seen
    assert FinalPricingRefusal.MATERIAL_NOT_CHOSEN.value in seen
    assert FinalPricingRefusal.CARD_UNAVAILABLE.value in seen


@pytest.mark.parametrize(
    "case",
    FIXTURES["einvoice_threshold_cases"],
    ids=[c["id"] for c in FIXTURES["einvoice_threshold_cases"]],
)
def test_einvoice_threshold_case(case: dict) -> None:
    """SPEC.md §10.2-§10.4. The RM10,000 rule.

    The two figures come off the real card, never from literals here: §10.3
    says the threshold lives in config because it will change, and a test that
    hard-coded it would keep passing after it did.
    """
    result = check_threshold(
        total=Money(case["total_sen"]),
        stage=ThresholdStage(case["stage"]),
        config=CARD.config.thresholds,
        buyer_details_complete=case["buyer_details_complete"],
        einvoice_requested=case["einvoice_requested"],
    )

    expected = case["expect"]
    assert result.must_capture is expected["must_capture"], "must_capture"
    assert result.blocks_advance is expected["blocks_advance"], "blocks_advance"
    assert (None if result.reason is None else result.reason.value) == expected[
        "reason"
    ], "reason"


def test_the_thresholds_come_off_the_card_not_out_of_the_code() -> None:
    # §10.3: "Threshold lives in config, not code. It will change." If it ever
    # stops being read from the card, this is where that shows up.
    assert CARD.config.einvoice_threshold_sen == 1_000_000
    assert CARD.config.einvoice_prompt_sen == 800_000

    # And the rule follows the card rather than a constant: moved thresholds
    # move the answer.
    moved = ThresholdConfig(threshold=Money(2_000_000), prompt=Money(1_500_000))
    assert (
        check_threshold(
            total=Money(1_200_000),
            stage=ThresholdStage.FINAL,
            config=moved,
        ).blocks_advance
        is False
    )


def test_every_threshold_reason_is_exercised() -> None:
    # A reason nothing covers is a branch that will be wrong the first time it
    # fires, and it fires on a legal obligation.
    seen = {
        case["expect"]["reason"]
        for case in FIXTURES["einvoice_threshold_cases"]
        if case["expect"]["reason"] is not None
    }
    assert seen == {reason.value for reason in ThresholdReason}


@pytest.mark.parametrize(
    "case",
    FIXTURES["buyer_details_cases"],
    ids=[c["id"] for c in FIXTURES["buyer_details_cases"]],
)
def test_buyer_details_case(case: dict) -> None:
    """SPEC.md §10.3. What counts as having the buyer's details."""
    buyer = BuyerDetails(**case["buyer"])

    assert buyer_details_complete(buyer) is case["expect"]["complete"]
    assert [m.value for m in missing_buyer_details(buyer)] == case["expect"]["missing"]


def test_every_missing_piece_is_exercised() -> None:
    # A branch nothing covers is one that will be wrong the first time it
    # fires, and it fires on a legal obligation.
    seen = {
        missing
        for case in FIXTURES["buyer_details_cases"]
        for missing in case["expect"]["missing"]
    }
    assert seen == {m.value for m in BuyerDetailsMissing}


def test_the_fixture_file_is_not_empty() -> None:
    # A green suite over an empty contract proves nothing.
    assert len(FIXTURES["cases"]) >= 20
    assert len(FIXTURES["quote_total_cases"]) >= 5
    assert len(FIXTURES["final_pricing_cases"]) >= 10
    assert len(FIXTURES["einvoice_threshold_cases"]) >= 12
    assert len(FIXTURES["buyer_details_cases"]) >= 10


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

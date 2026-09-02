"""The pricing engine. Mirrors `mobile/lib/pricing/engine.dart` step for step.

PURE. No FastAPI, no SQLAlchemy, no clock reads. Runnable in a test with no HTTP
and no database.

§9.4: on receipt the server re-prices every line from its recorded
``applied_rate_card_version``. A mismatch means this file and the Dart one have
drifted, and `shared/pricing-fixtures.json` is what stops that happening
silently. Every change here changes the fixture first.
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction

from ..core.length import Length, area_sqft
from ..core.money import ZERO, Money
from .models import (
    BandField,
    CustomerTier,
    DeliveryZone,
    DepositCategory,
    Fulfilment,
    Layer,
    PriceBasis,
    PricingRule,
    PricingStage,
    ProductRule,
    RateCard,
)


class NoApplicableRate(Exception):
    """No rule covers the requested product and dimensions.

    **Never fall back to the cheapest matching rule.** A missing band is a data
    error and must surface as one; guessing produces a confident wrong price.
    """

    def __init__(
        self,
        *,
        variant: str,
        material_key: str | None,
        band_value: Length | None,
        detail: str,
    ) -> None:
        self.variant = variant
        self.material_key = material_key
        self.band_value = band_value
        self.detail = detail
        material = f" ({material_key})" if material_key else ""
        super().__init__(f"NoApplicableRate: {variant}{material} -- {detail}")


class ProductRuleViolation(Exception):
    """A line breaches a constraint that is not a price.

    Distinct from NoApplicableRate: the rate card is fine, the order is not.
    """

    def __init__(self, *, rule: ProductRule, actual: Length) -> None:
        self.rule = rule
        self.actual = actual
        super().__init__(
            f"ProductRuleViolation: {rule.variant} {rule.kind} "
            f"{rule.dimension} {rule.value_tmm} -- got {actual.tmm}"
        )


@dataclass(frozen=True)
class LineRequest:
    variant: str
    width: Length
    material_key: str | None = None
    layer: Layer = Layer.SINGLE
    fulfilment: Fulfilment = Fulfilment.SUPPLY_INSTALL
    height: Length | None = None
    #: Identical windows priced together. Multiplies **after** the line rounds.
    quantity: int = 1


@dataclass(frozen=True)
class PricedLine:
    rule: PricingRule
    stage: PricingStage
    #: The exact quantity before any rounding or minimum.
    raw_qty: Fraction
    #: The quantity actually charged for, after minimum and stage rounding.
    billed_qty: Fraction
    billed_unit: str
    #: True when the rule's minimum quantity lifted the billed quantity.
    min_qty_applied: bool
    #: The rate before any tier substitution. Printed on the quote.
    standard_rate_sen: int
    rate_sen: int
    quantity: int
    total: Money
    #: True when no material was chosen and the **dearest** option was used.
    material_deferred: bool = False
    material_options: tuple[str, ...] = ()

    @property
    def deposit_category(self) -> DepositCategory:
        return self.rule.deposit_category

    @property
    def tier_rate_applied(self) -> bool:
        return self.rate_sen != self.standard_rate_sen


def price_line(
    *,
    request: LineRequest,
    card: RateCard,
    stage: PricingStage,
    tier: CustomerTier = CustomerTier.STANDARD,
) -> PricedLine:
    """Prices one line. §4.3.

    **Height selects the band. Height never multiplies.** For ``per_ft_width``
    only width is charged -- the single most likely thing to get wrong.
    """
    if request.quantity < 1:
        raise ValueError(f"quantity must be at least 1: {request.quantity}")

    # 0. Constraints that are not prices. A 25ft ZIP blind is not a wrong price,
    #    it is an order that cannot be fulfilled.
    _check_product_rules(card, request)

    # 1. Candidates for this product, before material.
    candidates = [
        r
        for r in card.rules
        if r.variant == request.variant
        and r.layer is request.layer
        and r.fulfilment is request.fulfilment
    ]
    if not candidates:
        raise NoApplicableRate(
            variant=request.variant,
            material_key=request.material_key,
            band_value=None,
            detail="no rule matches this variant, layer and fulfilment",
        )

    available_materials = {r.material_key for r in candidates if r.material_key}

    # 2. Material, if the customer has chosen one.
    if request.material_key is not None:
        candidates = [r for r in candidates if r.material_key == request.material_key]
        if not candidates:
            raise NoApplicableRate(
                variant=request.variant,
                material_key=request.material_key,
                band_value=None,
                detail=(
                    "no rule for that material -- available: "
                    + ", ".join(sorted(available_materials))
                ),
            )

    # 3. Band. Never pick the cheapest on a miss.
    banded = _select_band_candidates(candidates, request)

    # 4. Resolve a still-unchosen material.
    rule, material_deferred = _resolve_material(
        banded, request, stage, available_materials
    )

    # 5. Raw quantity by basis, exact.
    raw_qty = _raw_quantity(rule, request)

    # 6. Wastage. Not on the current card; the step exists so both engines keep
    #    the same ordering when it arrives.

    # 7. Minimum billed quantity, BEFORE the rate multiplies.
    after_min = raw_qty if rule.min_qty is None else max(raw_qty, rule.min_qty)
    min_qty_applied = rule.min_qty is not None and after_min != raw_qty

    # 8. Stage rounding. A quotation rounds up to a whole unit (A10); final
    #    pricing bills the measured quantity exactly (A11).
    if stage is PricingStage.ESTIMATE:
        billed_qty = Fraction(_ceil(after_min))
    else:
        billed_qty = after_min

    # 9. Tier rate. MVP is a flat substitute, never a percentage.
    rate_sen = rule.rate_for_tier(tier)

    # 10. Promo discount is Phase 2 work, blocked on A4. Deliberately absent
    #     rather than guessed.

    # 11. One rounding, at the line total, then multiply by identical windows.
    per_window = Money.round_from(billed_qty * rate_sen)
    total = per_window * request.quantity

    return PricedLine(
        rule=rule,
        stage=stage,
        raw_qty=raw_qty,
        billed_qty=billed_qty,
        billed_unit=rule.basis.unit,
        min_qty_applied=min_qty_applied,
        standard_rate_sen=rule.rate_sen,
        rate_sen=rate_sen,
        quantity=request.quantity,
        total=total,
        material_deferred=material_deferred,
        material_options=(
            tuple(sorted(available_materials)) if material_deferred else ()
        ),
    )


def _select_band_candidates(
    candidates: list[PricingRule], request: LineRequest
) -> list[PricingRule]:
    band_field = candidates[0].band_field
    if band_field is BandField.NONE:
        return candidates

    value = request.height if band_field is BandField.HEIGHT else request.width
    if value is None:
        raise NoApplicableRate(
            variant=request.variant,
            material_key=request.material_key,
            band_value=None,
            detail=f"this product is banded by {band_field.value}, which was not given",
        )

    matches = [r for r in candidates if r.band_contains(value)]
    if not matches:
        raise NoApplicableRate(
            variant=request.variant,
            material_key=request.material_key,
            band_value=value,
            detail=(
                f"no band covers {value.mm}mm -- a gap in the rate card, not a price"
            ),
        )
    return matches


def _resolve_material(
    candidates: list[PricingRule],
    request: LineRequest,
    stage: PricingStage,
    available_materials: set[str],
) -> tuple[PricingRule, bool]:
    """Picks the final rule, resolving a material not yet chosen.

    A deferred material is quoted at the **dearest** option, which is forced
    rather than chosen: §8.5 promises the final can only stay level or fall, and
    quoting the cheaper material would make it go up.
    """
    if len(candidates) == 1:
        return candidates[0], False

    distinct = {r.material_key for r in candidates}
    if len(distinct) != len(candidates):
        raise NoApplicableRate(
            variant=request.variant,
            material_key=request.material_key,
            band_value=None,
            detail=(
                f"{len(candidates)} rules match and they do not differ only by "
                "material; the card is ambiguous"
            ),
        )

    if stage is PricingStage.FINAL:
        # Final pricing happens with the customer's actual choice in hand.
        # Guessing there would invoice a material nobody chose.
        raise NoApplicableRate(
            variant=request.variant,
            material_key=None,
            band_value=None,
            detail=(
                "material must be chosen before final pricing -- one of "
                + ", ".join(sorted(available_materials))
            ),
        )

    return max(candidates, key=lambda r: r.rate_sen), True


def _raw_quantity(rule: PricingRule, request: LineRequest) -> Fraction:
    basis = rule.basis
    if basis is PriceBasis.PER_FT_WIDTH:
        return request.width.feet_exact

    if basis is PriceBasis.PER_SQFT:
        if request.height is None:
            raise NoApplicableRate(
                variant=request.variant,
                material_key=request.material_key,
                band_value=None,
                detail="per_sqft needs a height",
            )
        return area_sqft(request.width, request.height)

    if basis is PriceBasis.PER_M_LENGTH:
        return Fraction(request.width.tmm, 10_000)

    if basis in (PriceBasis.PER_PIECE, PriceBasis.PER_SET):
        return Fraction(1)

    # per_roll. `coverage_sqft` is the area ONE CHARGE covers, not one roll;
    # `bundle_qty` records how many rolls that charge delivers and deliberately
    # does not divide here. Dividing twice would halve the quote.
    #
    # Pattern-repeat wastage is NOT applied: §13 A7 asks whether it is already
    # absorbed in the roll price, and a guessed percentage would silently
    # overcharge on every wall.
    if request.height is None or not rule.coverage_sqft:
        raise NoApplicableRate(
            variant=request.variant,
            material_key=request.material_key,
            band_value=None,
            detail="per_roll needs a height and a coverage_sqft on the rule",
        )
    return area_sqft(request.width, request.height) / rule.coverage_sqft


def _check_product_rules(card: RateCard, request: LineRequest) -> None:
    for rule in card.product_rules:
        if rule.variant != request.variant or rule.value_tmm is None:
            continue
        value = request.width if rule.dimension == "width" else request.height
        if value is None:
            continue
        breached = (rule.kind == "max_dimension" and value.tmm > rule.value_tmm) or (
            rule.kind == "min_dimension" and value.tmm < rule.value_tmm
        )
        if breached:
            raise ProductRuleViolation(rule=rule, actual=value)
    # `requires` and `excludes` need the whole order, so check_order_rules
    # handles them.


@dataclass(frozen=True)
class OrderRuleViolation:
    """A `requires` or `excludes` rule the quote as a whole breaks."""

    rule: ProductRule
    variant: str


def check_order_rules(
    *, lines: list[PricedLine], card: RateCard
) -> list[OrderRuleViolation]:
    """Rules that only make sense across a whole quote.

    Returned rather than raised. A missing self levelling is not a reason to
    refuse the quote -- it is a reason to tell the salesperson to add a line
    while the customer is still standing there. Refusing loses the sale; silence
    loses the floor.
    """
    present = {line.rule.variant for line in lines}
    out: list[OrderRuleViolation] = []
    for rule in card.product_rules:
        if rule.variant not in present or rule.target is None:
            continue
        breached = (rule.kind == "requires" and rule.target not in present) or (
            rule.kind == "excludes" and rule.target in present
        )
        if breached:
            out.append(OrderRuleViolation(rule=rule, variant=rule.variant))
    return out


@dataclass(frozen=True)
class QuoteTotals:
    category_subtotals: dict[DepositCategory, Money]
    category_floor_uplift: dict[DepositCategory, Money]
    total: Money
    delivery_zone: DeliveryZone | None = None
    delivery_charge: Money = ZERO

    @property
    def any_floor_applied(self) -> bool:
        return any(not m.is_zero for m in self.category_floor_uplift.values())


def total_quote(
    *,
    lines: list[PricedLine],
    card: RateCard,
    stage: PricingStage,
    delivery_zone_id: str | None = None,
) -> QuoteTotals:
    """Totals priced lines, applying the RM300 per-category floor.

    §4.3: the floor is an **order-level** step and applies to the quotation
    only. A customer quoted RM250 who pays a RM300 deposit has overpaid, and
    will argue about it at measurement.
    """
    subtotals: dict[DepositCategory, Money] = {}
    for line in lines:
        cat = line.deposit_category
        subtotals[cat] = subtotals.get(cat, ZERO) + line.total

    uplift: dict[DepositCategory, Money] = {}
    total = ZERO
    floor = Money(card.config.min_deposit_sen)

    for cat, raw in subtotals.items():
        floored = raw.max(floor) if stage is PricingStage.ESTIMATE else raw
        uplift[cat] = floored - raw
        total = total + floored

    # Travel is order-level and sits outside the deposit categories: it is not
    # a product, so a category floor must not drag it upward.
    zone = next((z for z in card.delivery_zones if z.id == delivery_zone_id), None)
    delivery = ZERO if zone is None else Money(zone.charge_sen)

    return QuoteTotals(
        category_subtotals=subtotals,
        category_floor_uplift=uplift,
        delivery_zone=zone,
        delivery_charge=delivery,
        total=total + delivery,
    )


def _ceil(value: Fraction) -> int:
    if value.denominator == 1:
        return value.numerator
    return -((-value.numerator) // value.denominator)

"""Repricing a measured order. SPEC.md §11 Phase 6, §6.1, §8.5.

Mirrors ``mobile/lib/pricing/final_pricing.dart`` decision for decision, and the
two are held together by ``shared/pricing-fixtures.json`` under
``final_pricing_cases``.

    A measured order reprices at the old card even after two rate publishes

That is the phase's first acceptance criterion and the reason a rate lock is
worth RM300 to a customer. Every line prices at the card version and discount
**it recorded when it was quoted** -- never at the active card, and never at the
order's pinned version, because a line's lock is its own (§6.1: applying a
curtain lock to a flooring line is the expensive bug in this design).

**Quantity is exact.** The quote rounded every quantity up to a whole unit; the
bill does not. That asymmetry is the product, not an artefact, and it is what
makes the estimate a ceiling the final can only fall below.

**Nothing falls back.** A line the tape has not reached, a material nobody
chose, or a card version not to hand refuses and says which. Every fallback
would be a number on an invoice nobody can explain a year later -- and the one
fallback that looks most reasonable, using today's card when the held one is
missing, is precisely what the deposit was taken to prevent.

**A refused line stops the order total, not just its own.** An order total that
quietly excluded a line would be a balance somebody collects and a window nobody
bills for.

Pure. No I/O, no ORM, no clock.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum
from fractions import Fraction

from ..core.length import Length
from ..core.money import ZERO, Money
from .engine import LineRequest, NoApplicableRate, PricedLine, price_line
from .models import (
    CustomerTier,
    DepositCategory,
    Fulfilment,
    Layer,
    PricingStage,
    RateCard,
    UnknownDepositCategory,
)


class FinalPricingRefusal(Enum):
    """Why one line could not be finally priced."""

    #: No tape has been taken to it. Five of six windows measured is not a
    #: measured order.
    NOT_MEASURED = "not_measured"

    #: Quoted at the dearest option in its group (§13 B7) and still unchosen.
    #: Nobody is invoiced for a material they never picked.
    MATERIAL_NOT_CHOSEN = "material_not_chosen"

    #: The card version this line recorded is not among those supplied. Using
    #: another one would silently reprice a held order.
    CARD_UNAVAILABLE = "card_unavailable"

    #: The card was found and could not price the line -- a variant withdrawn,
    #: a band that no longer covers the measured drop. Reported rather than
    #: raised, so one impossible line does not lose the other five.
    NO_APPLICABLE_RATE = "no_applicable_rate"


@dataclass(frozen=True)
class MeasuredLine:
    """One line as it stood when the measurer arrived."""

    id: str
    variant: str
    #: What the quotation charged. Kept beside the final rather than replaced
    #: by it, so §6.3's variance report has both to compare.
    estimate_total: Money
    #: The version this line was priced at. **This** is what reprices it.
    applied_rate_card_version: int

    material_key: str | None = None
    layer: Layer = Layer.SINGLE
    fulfilment: Fulfilment = Fulfilment.SUPPLY_INSTALL
    quantity: int = 1

    #: The tape. None until somebody has taken it.
    final_width: Length | None = None
    final_height: Length | None = None

    #: True while the line is still carrying the dearest option in its group.
    material_deferred: bool = False

    @property
    def is_measured(self) -> bool:
        return self.final_width is not None


@dataclass(frozen=True)
class FinalLine:
    """One line after measurement."""

    id: str
    estimate_total: Money
    #: The card version this actually priced at, None when it refused.
    priced_at_version: int | None = None
    priced: PricedLine | None = None
    refusal: FinalPricingRefusal | None = None

    @property
    def final_total(self) -> Money | None:
        return None if self.priced is None else self.priced.total

    @property
    def variance(self) -> Money | None:
        """``final - estimate``. Negative is the expected direction: the quote
        rounds every quantity up and the bill does not."""
        total = self.final_total
        return None if total is None else total - self.estimate_total

    @property
    def is_over_estimate(self) -> bool:
        """The window is genuinely bigger than the customer said at the fair.

        §8.5's promise is about rounding, not about the customer's own wrong
        dimensions, so this is flagged rather than refused -- refusing would
        block a real order. §6.3's variance report counts these separately
        instead of averaging them away.
        """
        variance = self.variance
        return variance is not None and variance.sen > 0

    @property
    def billed_qty(self) -> Fraction | None:
        """The exact quantity billed, for a screen that shows its working.

        §11 Phase 6 wants the variance visible to the measurer before they
        leave the house, and "12ft quoted, 11.48ft measured" is the sentence
        that explains the number.
        """
        return None if self.priced is None else self.priced.billed_qty


@dataclass(frozen=True)
class FinalPricing:
    """A whole order after site measurement."""

    lines: list[FinalLine] = field(default_factory=list)
    estimate_total: Money = ZERO
    #: None until every line has priced. An order total that quietly excluded a
    #: line would be a balance somebody collects and a window nobody bills for.
    final_total: Money | None = None
    #: True when every line priced, and there was at least one.
    is_complete: bool = False

    #: True when the job cleared the threshold and every printed minimum was
    #: stood down. §13 A21.
    min_qty_waived: bool = False

    #: What the lines came to with no minimum applied -- the number the waiver
    #: decision was actually made on (A21b). None until the order fully prices.
    #:
    #: Kept because a rule that turns on a comparison is unreadable without the
    #: figure it compared: "RM324, which cleared RM300" is a sentence somebody
    #: can check, and "the minimums were waived" is not.
    exact_subtotal: Money | None = None

    #: What §8.4's per-category deposit floor added on top of the lines. A21d.
    #:
    #: An order-level number, deliberately not pushed back into the lines: a
    #: line has to keep saying what its own product cost, or the variance
    #: report compares an estimate against a figure that was never a price.
    category_floor_uplift: Money = ZERO

    @property
    def variance(self) -> Money | None:
        return (
            None if self.final_total is None else self.final_total - self.estimate_total
        )

    @property
    def outstanding(self) -> list[FinalLine]:
        """What the measurer still has to do before they leave the house."""
        return [line for line in self.lines if line.refusal is not None]

    @property
    def over_estimate(self) -> list[FinalLine]:
        """Lines whose tape came in above the estimate. §8.5 says this cannot be
        a rounding artefact, so each is a real discrepancy worth a
        conversation."""
        return [line for line in self.lines if line.is_over_estimate]


def reprice_order(
    *,
    lines: list[MeasuredLine],
    cards: dict[int, RateCard],
    tier: CustomerTier = CustomerTier.STANDARD,
) -> FinalPricing:
    """Reprices a measured order. SPEC.md §11 Phase 6.

    ``cards`` is keyed by version and holds every published card the caller
    has. A line whose version is missing refuses; it is never priced at
    another.
    """
    # §13 A21, in the order the answer fixes -- and the order matters.
    #
    # Pass 1 prices every line from the tape with NO minimum, which gives the
    # exact subtotal. Pass 2 decides. The threshold is measured against the
    # exact prices and never against the minimum-applied ones (A21b): the other
    # reading is circular, because the minimums are what the decision produces.
    exact = [_reprice_line(line, cards, tier, apply_min_qty=False) for line in lines]

    # A21a: the WHOLE order, not the deposit category. A house of curtains and
    # one small blind is one job, and the blind rides along with it.
    #
    # Only lines that actually priced contribute. A refused line has no number,
    # and treating a missing one as zero would drag a job under the threshold
    # and bill minimums the customer should not have paid.
    exact_subtotal = sum(
        (line.final_total for line in exact if line.final_total is not None), ZERO
    )

    threshold = _waiver_threshold(lines, cards)
    every_line_priced = bool(exact) and all(line.refusal is None for line in exact)

    # A21c: exactly the threshold clears it. RM300 is also the deposit figure,
    # so an order landing on it is the common case rather than a corner one.
    waived = (
        every_line_priced
        and threshold is not None
        and exact_subtotal.sen >= threshold.sen
    )

    priced = (
        exact
        if waived
        else [_reprice_line(line, cards, tier, apply_min_qty=True) for line in lines]
    )

    # An order with no lines has not been priced. Zero is a total somebody could
    # act on, and "RM0.00 due" is a worse answer than "not priced".
    complete = bool(priced) and all(line.refusal is None for line in priced)

    uplift = (
        _category_floor_uplift(priced, cards, lambda l: l.final_total)
        if complete
        else ZERO
    )
    estimate_uplift = (
        _category_floor_uplift(priced, cards, lambda l: l.estimate_total)
        if complete
        else ZERO
    )

    estimate = sum((line.estimate_total for line in priced), ZERO) + estimate_uplift

    return FinalPricing(
        lines=priced,
        estimate_total=estimate,
        min_qty_waived=waived,
        exact_subtotal=exact_subtotal if complete else None,
        category_floor_uplift=uplift,
        # The lines, plus whatever the per-category deposit floor added on top.
        final_total=(
            sum((line.final_total for line in priced), ZERO) + uplift
            if complete
            else None
        ),
        is_complete=complete,
    )


def _waiver_threshold(
    lines: list[MeasuredLine], cards: dict[int, RateCard]
) -> Money | None:
    """The lowest waiver threshold among the cards this order's lines priced at.

    Lines can sit on different card versions -- a lock is per line -- and those
    cards can carry different config. The lowest is the customer-favourable
    reading and the only one that does not depend on line order. None when no
    line could name its card, in which case nothing is waived.
    """
    lowest: Money | None = None
    for line in lines:
        card = cards.get(line.applied_rate_card_version)
        if card is None:
            continue
        value = card.config.min_qty_waiver
        if lowest is None or value.sen < lowest.sen:
            lowest = value
    return lowest


def _category_floor_uplift(
    priced: list[FinalLine],
    cards: dict[int, RateCard],
    amount_of: Callable[[FinalLine], Money | None],
) -> Money:
    """§8.4's per-category deposit floor, now applied at final pricing too.

    §13 A21d: waiving a minimum can drop a final below the deposit the customer
    already handed over, and the answer is that it never bills below it. Same
    rule as the quotation, so the two documents cannot contradict each other --
    and §8.5's promise survives, because a quote that was itself floored to
    RM300 is met exactly rather than undercut.

    ``amount_of`` selects which figure to floor. It is run over BOTH the final
    and the estimate: the quotation the customer holds already had this floor
    applied, but only as an order-level uplift, so a sum of the recorded line
    estimates is short by it. Flooring only the final would make every small
    order look like its price went **up** -- the one thing §8.5 says cannot
    happen, invented by the arithmetic rather than by anything real.

    Returns the total uplift across every category, in sen.
    """
    subtotals: dict[DepositCategory, Money] = {}
    floors: dict[DepositCategory, Money] = {}

    for line in priced:
        rule = None if line.priced is None else line.priced.rule
        if rule is None:
            continue

        # An unparented add-on has no deposit category, and `deposit_category`
        # raises rather than guessing one -- correctly, because filing it under
        # curtains could price it at a held rate its RM300 never bought.
        #
        # It is skipped for FLOORING only, and its total still counts in the
        # order. No category means no deposit was ever taken against it, so it
        # cannot pull a category under a floor and must not invent one.
        try:
            cat = rule.deposit_category
        except UnknownDepositCategory:
            continue

        amount = amount_of(line)
        if amount is None:
            continue
        subtotals[cat] = subtotals.get(cat, ZERO) + amount

        # The floor comes off the card that priced the line, like every other
        # configured figure -- never off today's active card.
        card = (
            None
            if line.priced_at_version is None
            else cards.get(line.priced_at_version)
        )
        if card is None:
            continue
        floor = Money(card.config.min_deposit_sen)
        known = floors.get(cat)
        # Lowest again, for the same reason as the waiver threshold.
        if known is None or floor.sen < known.sen:
            floors[cat] = floor

    uplift = ZERO
    for cat, subtotal in subtotals.items():
        floor = floors.get(cat)
        if floor is None:
            continue
        if subtotal.sen < floor.sen:
            uplift = uplift + (floor - subtotal)
    return uplift


def _reprice_line(
    line: MeasuredLine,
    cards: dict[int, RateCard],
    tier: CustomerTier,
    *,
    apply_min_qty: bool,
) -> FinalLine:
    def refuse(why: FinalPricingRefusal) -> FinalLine:
        return FinalLine(id=line.id, estimate_total=line.estimate_total, refusal=why)

    if not line.is_measured:
        return refuse(FinalPricingRefusal.NOT_MEASURED)

    # Checked before the card is looked up, so a line whose material nobody
    # chose says so even when the card is also missing. The material is the one
    # the measurer can fix while standing in the house.
    if line.material_deferred and line.material_key is None:
        return refuse(FinalPricingRefusal.MATERIAL_NOT_CHOSEN)

    card = cards.get(line.applied_rate_card_version)
    if card is None:
        return refuse(FinalPricingRefusal.CARD_UNAVAILABLE)

    try:
        result = price_line(
            request=LineRequest(
                variant=line.variant,
                material_key=line.material_key,
                layer=line.layer,
                fulfilment=line.fulfilment,
                width=line.final_width,
                height=line.final_height,
                quantity=line.quantity,
            ),
            card=card,
            stage=PricingStage.FINAL,
            tier=tier,
            apply_min_qty=apply_min_qty,
        )
    except NoApplicableRate:
        # One line that cannot be priced must not lose the other five. The
        # measurer needs to know which window is the problem, in the house.
        return refuse(FinalPricingRefusal.NO_APPLICABLE_RATE)

    return FinalLine(
        id=line.id,
        estimate_total=line.estimate_total,
        priced_at_version=line.applied_rate_card_version,
        priced=result,
    )

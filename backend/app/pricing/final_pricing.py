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

from dataclasses import dataclass, field
from enum import Enum
from fractions import Fraction

from ..core.length import Length
from ..core.money import ZERO, Money
from .engine import LineRequest, NoApplicableRate, PricedLine, price_line
from .models import CustomerTier, Fulfilment, Layer, PricingStage, RateCard


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
    priced = [_reprice_line(line, cards, tier) for line in lines]

    estimate = sum((line.estimate_total for line in priced), ZERO)

    # An order with no lines has not been priced. Zero is a total somebody could
    # act on, and "RM0.00 due" is a worse answer than "not priced".
    complete = bool(priced) and all(line.refusal is None for line in priced)

    return FinalPricing(
        lines=priced,
        estimate_total=estimate,
        final_total=(
            sum((line.final_total for line in priced), ZERO) if complete else None
        ),
        is_complete=complete,
    )


def _reprice_line(
    line: MeasuredLine, cards: dict[int, RateCard], tier: CustomerTier
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

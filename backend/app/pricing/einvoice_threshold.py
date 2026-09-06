"""The RM10,000 rule. SPEC.md §10.2, §10.3, §10.4.

Mirrors ``mobile/lib/pricing/einvoice_threshold.dart`` decision for decision,
and the two are held together by ``shared/pricing-fixtures.json`` under
``einvoice_threshold_cases``.

Since **1 January 2026** any single transaction above RM10,000 must have its own
individual e-invoice and cannot go into a monthly consolidated batch. B2C as
much as B2B. Penalties run RM200 to RM20,000 **per non-compliant invoice**, and
§10.2 is blunt that this is not an edge case here:

    Full-house curtain orders routinely exceed RM10,000. A meaningful share of
    sales legally require buyer identification, not a "General Public" receipt.

SQL Account issues the invoice and flags what is over the threshold. **The gap
is upstream**: it can only issue an individual e-invoice if somebody captured
the buyer's details, and that has to happen while the customer is standing
there.

## Checked twice, on purpose

§10.4's timing trap: *"An order estimated at RM8,500 settles at RM11,200."*

1. **On the estimate, at the fair** -- prompt from RM8,000, not RM10,000, so
   borderline orders are captured while somebody can still be asked. Below the
   legal line this only *asks*: refusing a RM300 deposit over paperwork the
   order does not yet need would lose the sale.
2. **On the final, after measurement** -- if crossed, the order cannot advance.
   §10.4: *"Enforce in the state machine, not the UI."*

The RM8,000 margin belongs to the estimate alone. An estimate is rough and the
margin buys a chance to ask; a final is exact, so an order that measured under
the threshold is under it.

**Both numbers are config on the rate card**, never literals here (§10.3:
*"Threshold lives in config, not code. It will change."*).

Nothing in this file prints, names or numbers a document. CLAUDE.md hard rule 7
stands: SQL Account is the sole issuer of record.

Pure. No I/O, no ORM, no clock.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from ..core.money import Money


class ThresholdStage(Enum):
    """Which figure is being checked."""

    #: At the fair, on the estimate. Carries the RM8,000 margin.
    ESTIMATE = "estimate"

    #: After site measurement, on the exact figure. No margin.
    FINAL = "final"


class ThresholdReason(Enum):
    """Why buyer details are wanted."""

    #: Inside §10.4's margin -- RM8,000 or more, under the legal line. Ask now,
    #: because this may well cross after measurement.
    NEAR_THRESHOLD = "near_threshold"

    #: At or over the legal line. §10.3: not a warning, a required step.
    OVER_THRESHOLD = "over_threshold"

    #: The customer asked for an e-invoice, at any value (§10.3).
    EINVOICE_REQUESTED = "einvoice_requested"


@dataclass(frozen=True)
class ThresholdCheck:
    """What the threshold rule says about one order."""

    #: Buyer details are wanted. Ask.
    must_capture: bool
    #: And the order may not go on without them. §10.3: *"Not a warning. A
    #: required step."*
    blocks_advance: bool
    #: None when nothing is wanted.
    reason: ThresholdReason | None = None


NONE = ThresholdCheck(must_capture=False, blocks_advance=False)


@dataclass(frozen=True)
class ThresholdConfig:
    """The two figures, off the rate card. §10.3: config, not code."""

    #: At or over this, buyer details are required. RM10,000.
    threshold: Money
    #: At or over this, the quote wizard asks. RM8,000, and only on an estimate.
    prompt: Money


def check_threshold(
    *,
    total: Money,
    stage: ThresholdStage,
    config: ThresholdConfig,
    buyer_details_complete: bool = False,
    einvoice_requested: bool = False,
) -> ThresholdCheck:
    """Whether an order needs buyer details, and whether it may move without.

    ``buyer_details_complete`` is the only thing that clears it. The
    requirement is the details, not the ceremony: once they exist the order
    moves, at any value.
    """
    if buyer_details_complete:
        return NONE

    # §10.3: required whenever the customer asks, at any value. Checked first
    # because it holds regardless of the amount -- a RM552 order for somebody
    # who wants to claim it is as much a compliance obligation as a RM15,000
    # one.
    if einvoice_requested:
        return ThresholdCheck(
            must_capture=True,
            blocks_advance=True,
            reason=ThresholdReason.EINVOICE_REQUESTED,
        )

    # At exactly RM10,000, not above it. §10.2 says "above RM10,000" and §10.3
    # says the wizard stops when the total "crosses the threshold"; stopping at
    # the round number is the conservative direction, because capturing details
    # for one order that did not need them costs a minute and missing one costs
    # up to RM20,000.
    if total.sen >= config.threshold.sen:
        return ThresholdCheck(
            must_capture=True,
            blocks_advance=True,
            reason=ThresholdReason.OVER_THRESHOLD,
        )

    # The margin is the estimate's alone. A final is exact: an order that
    # measured under the threshold is under it, and asking at that point is
    # friction with no compliance behind it.
    if stage is ThresholdStage.ESTIMATE and total.sen >= config.prompt.sen:
        return ThresholdCheck(
            must_capture=True,
            # Asks, does not stop. The order is not over the legal line, and
            # refusing a deposit over paperwork it does not yet need loses the
            # sale.
            blocks_advance=False,
            reason=ThresholdReason.NEAR_THRESHOLD,
        )

    return NONE


@dataclass(frozen=True)
class BuyerDetails:
    """What the invoice needs about the buyer. SPEC.md §10.3.

    Optional by default: most walk-ins are General Public and never fill any of
    this in. It becomes required when the threshold rule says so.
    """

    name: str | None = None

    #: Tax identification number. Either this or an ID satisfies the
    #: identifier.
    tin: str | None = None

    #: ``nric``, ``brn``, ``passport`` or ``army``. Needed *with*
    #: ``id_number``: a number with no type cannot be filed, because an IC, a
    #: passport and a business registration are different fields on the
    #: invoice.
    id_type: str | None = None
    id_number: str | None = None

    address_line1: str | None = None
    #: Optional. Plenty of addresses are one line, and requiring a second would
    #: make staff type something to get past it.
    address_line2: str | None = None
    city: str | None = None
    state: str | None = None
    postcode: str | None = None


class BuyerDetailsMissing(Enum):
    """What is still missing from a buyer record."""

    NAME = "name"
    #: Neither a TIN nor a complete ID.
    IDENTIFIER = "identifier"
    #: Line 1, city, state or postcode is blank.
    ADDRESS = "address"


def _filled(value: str | None) -> bool:
    return value is not None and value.strip() != ""


def missing_buyer_details(buyer: BuyerDetails) -> list[BuyerDetailsMissing]:
    """Everything still outstanding, in a fixed order.

    All of it at once, so somebody collects it in one conversation. A form that
    reveals one missing field at a time is a customer asked three times.
    """
    missing = []
    if not _filled(buyer.name):
        missing.append(BuyerDetailsMissing.NAME)
    if not _filled(buyer.tin) and not (
        _filled(buyer.id_type) and _filled(buyer.id_number)
    ):
        missing.append(BuyerDetailsMissing.IDENTIFIER)
    if not (
        _filled(buyer.address_line1)
        and _filled(buyer.city)
        and _filled(buyer.state)
        and _filled(buyer.postcode)
    ):
        missing.append(BuyerDetailsMissing.ADDRESS)
    return missing


def buyer_details_complete(buyer: BuyerDetails) -> bool:
    """Whether the buyer record is enough to issue an e-invoice from. §10.3.

    A rule rather than a flag somebody sets: a tick box gets ticked by anyone
    in a hurry, and the row it ticks is what SQL Account has to build a real
    e-invoice from. §13 C13 asks the accountant which fields MyInvois actually
    rejects; until then this asks for the minimum any invoice needs, erring
    toward too much because §10.2's penalty is for missing details.
    """
    return not missing_buyer_details(buyer)

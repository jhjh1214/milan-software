"""A staff or admin member changing one product's live price directly.

Mirrors `price_override.py`'s own shape -- a pure decision, an audit-record
description, a refused-because enum -- for the same reason that file gives:
the gate is a speed bump, and what actually stops abuse is that every move
is recorded against a name, with a reason, and read back later.

What moves is different. An order-line override corrects one line on one
already-confirmed order. This corrects a *catalog* price -- the next
person to quote this product, anywhere, gets the new rate -- so the row
this produces is the audit trail for a new `RateCardVersion`, not for a
line total.

Authorisation is the caller's job: this module is only ever reached
through a route already gated to staff or admin (part-timers never see a
rate at all, hard rule 8), so it takes `by_user_id` as given rather than a
role to check -- unlike `price_override.py`, which has to trust a role a
device merely claims.

Pure. No clock read, no I/O, no ORM.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

#: Same bar as an order-line override (SPEC.md §6.5): short enough to type
#: at a fair table, long enough to mean something in the weekly review.
MIN_REASON_LENGTH = 4


class RateEditRefusal(Enum):
    """Why a live price edit was refused."""

    #: No product with this id on the active card for this list.
    NO_SUCH_PRODUCT = "no_such_product"

    #: Missing, or too short to mean anything once trimmed.
    NO_REASON = "no_reason"

    #: Zero or negative. A catalog rate of RM0 reads as "free forever", not
    #: "no price yet" -- the same confusion the provisional-row rule (A22)
    #: already refuses to let happen.
    NOT_POSITIVE = "not_positive"

    #: Both rates are already exactly this. Nothing to record, and a row
    #: saying RM46 became RM46 is the noise that stops the review being read.
    NO_CHANGE = "no_change"


@dataclass(frozen=True, slots=True)
class RateEditRecord:
    """The audit row an accepted edit calls for, and what the new card's
    row should carry. Append-only, never deletable from the app."""

    rule_id: str
    list_id: str
    before_rate_sen: int
    after_rate_sen: int
    before_mvp_rate_sen: int | None
    after_mvp_rate_sen: int | None

    #: Trimmed, and guaranteed at least `MIN_REASON_LENGTH` characters.
    reason: str

    #: Never empty. The whole control is that this names somebody.
    by_user_id: str


@dataclass(frozen=True, slots=True)
class RateEditDecision:
    """The outcome of asking to change one product's price."""

    record: RateEditRecord | None = None
    refused_because: RateEditRefusal | None = None

    @property
    def is_applied(self) -> bool:
        return self.record is not None


def decide_rate_edit(
    *,
    rule_id: str,
    list_id: str,
    before_rate_sen: int | None,
    after_rate_sen: int,
    before_mvp_rate_sen: int | None,
    after_mvp_rate_sen: int | None,
    reason: str | None,
    by_user_id: str,
) -> RateEditDecision:
    """Decide whether one product's price may change, and to what.

    `before_rate_sen` is `None` when `rule_id` does not name a row on the
    active card for `list_id` -- refused rather than silently creating one,
    since a live price edit is for a product that already exists.
    """
    if before_rate_sen is None:
        return RateEditDecision(refused_because=RateEditRefusal.NO_SUCH_PRODUCT)

    given = (reason or "").strip()
    if len(given) < MIN_REASON_LENGTH:
        return RateEditDecision(refused_because=RateEditRefusal.NO_REASON)

    if after_rate_sen <= 0 or (
        after_mvp_rate_sen is not None and after_mvp_rate_sen <= 0
    ):
        return RateEditDecision(refused_because=RateEditRefusal.NOT_POSITIVE)

    if after_rate_sen == before_rate_sen and after_mvp_rate_sen == before_mvp_rate_sen:
        return RateEditDecision(refused_because=RateEditRefusal.NO_CHANGE)

    return RateEditDecision(
        record=RateEditRecord(
            rule_id=rule_id,
            list_id=list_id,
            before_rate_sen=before_rate_sen,
            after_rate_sen=after_rate_sen,
            before_mvp_rate_sen=before_mvp_rate_sen,
            after_mvp_rate_sen=after_mvp_rate_sen,
            reason=given,
            by_user_id=by_user_id,
        )
    )

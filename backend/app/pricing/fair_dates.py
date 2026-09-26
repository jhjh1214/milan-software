"""An admin setting when a fair runs.

The fair's dates are the fair card's promo window, and they decide two
things that are about money: which days a handset may quote fair prices at
all (fair mode closes with the window), and when every deposit taken at that
fair stops holding its price (twelve months from the day after the window
ends, SPEC.md §6.1). So they are data an admin edits -- never a date in code
-- and each change is recorded against a name with a reason, the same
discipline `rate_edit.py` applies to one product's price.

Admin only, and that is the route's job: this module takes `by_user_id` as
given, exactly as `rate_edit.py` does.

Pure. No clock read, no I/O, no ORM.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from enum import Enum

from .rate_edit import MIN_REASON_LENGTH

#: The promo code keys the fair-performance report, so it has to be a real
#: label rather than a paragraph.
MAX_CODE_LENGTH = 64


@dataclass(frozen=True, slots=True)
class FairDates:
    code: str
    valid_from: date
    valid_to: date


class FairDatesRefusal(Enum):
    """Why a change to a fair's dates was refused."""

    #: Missing, or too short to mean anything once trimmed.
    NO_REASON = "no_reason"

    #: Empty once trimmed, or too long to be a label.
    BAD_CODE = "bad_code"

    #: Ends before it starts. A one-day fair is fine; a negative one is a typo.
    ENDS_BEFORE_IT_STARTS = "ends_before_it_starts"

    #: Code and both dates already exactly this. A row saying nothing moved
    #: is the noise that stops the review being read.
    NO_CHANGE = "no_change"


@dataclass(frozen=True, slots=True)
class FairDatesRecord:
    """The audit row an accepted change calls for. Append-only."""

    before: FairDates | None
    after: FairDates

    #: Trimmed, and guaranteed at least `MIN_REASON_LENGTH` characters.
    reason: str

    #: Never empty. The whole control is that this names somebody.
    by_user_id: str


@dataclass(frozen=True, slots=True)
class FairDatesDecision:
    record: FairDatesRecord | None = None
    refused_because: FairDatesRefusal | None = None

    @property
    def is_applied(self) -> bool:
        return self.record is not None


def decide_fair_dates(
    *,
    before: FairDates | None,
    code: str,
    valid_from: date,
    valid_to: date,
    reason: str | None,
    by_user_id: str,
) -> FairDatesDecision:
    """Decide whether the fair card's dates may become these.

    `before` is `None` when the card carries no promo window yet -- setting
    one for the first time is exactly what this is for, so it is not refused.
    """
    given = (reason or "").strip()
    if len(given) < MIN_REASON_LENGTH:
        return FairDatesDecision(refused_because=FairDatesRefusal.NO_REASON)

    label = code.strip()
    if not label or len(label) > MAX_CODE_LENGTH:
        return FairDatesDecision(refused_because=FairDatesRefusal.BAD_CODE)

    if valid_to < valid_from:
        return FairDatesDecision(refused_because=FairDatesRefusal.ENDS_BEFORE_IT_STARTS)

    after = FairDates(code=label, valid_from=valid_from, valid_to=valid_to)
    if after == before:
        return FairDatesDecision(refused_because=FairDatesRefusal.NO_CHANGE)

    return FairDatesDecision(
        record=FairDatesRecord(
            before=before, after=after, reason=given, by_user_id=by_user_id
        )
    )

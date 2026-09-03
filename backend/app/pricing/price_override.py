"""An admin moving a line's total by hand. SPEC.md §6.5.

Mirrors ``mobile/lib/pricing/price_override.dart`` decision for decision, and
the two are held together by ``shared/pricing-fixtures.json`` under
``price_override_cases``.

The server re-validates an override before it accepts one. An override the
server refuses would otherwise leave a handset showing a price nothing else
agrees with, and the handset is the copy the customer was shown.

The spec is blunt about where the control actually is, and it is worth
repeating next to the code::

    An offline PIN is bypassable, and one shared admin password reaches every
    part-timer within a month. The real control is the audit log plus a weekly
    review screen, not the gate. Individual PINs so the log names a person, and
    build the "overrides this week" screen -- without it the log is never read
    and the control does not exist.

So the admin check is a speed bump and the row is the point. Two rules follow,
both about the weekly review staying readable: an override must name a person,
and an override that changes nothing is refused, because a row saying RM552
became RM552 is noise and noise is what stops the review being read.

A negative total is refused -- a refund is a payment of kind ``refund`` (§6.4),
not a line costing less than nothing. Zero is allowed: a write-off or a remake
at our cost, which is exactly the case the review most needs to surface.

A finished order is refused. Closed or cancelled, its number is on a document
the customer already has.

Pure. No clock read, no I/O, no ORM. The row is described, not written.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

#: The shortest reason that says anything. SPEC.md §6.5: "reason mandatory,
#: minimum 4 characters. No empty-string bypass." Cancelling an order borrows
#: this bar, for the same reason.
MIN_REASON_LENGTH = 4


class OverrideRefusal(Enum):
    """Why an override was refused."""

    #: Not an admin, or an admin the log cannot name.
    NOT_AN_ADMIN = "not_an_admin"

    #: Missing, or too short to mean anything once trimmed.
    NO_REASON = "no_reason"

    #: A line that costs less than nothing.
    NEGATIVE_TOTAL = "negative_total"

    #: The total is already that. Nothing to record.
    NO_CHANGE = "no_change"

    #: The order is closed or cancelled.
    ORDER_FINISHED = "order_finished"


@dataclass(frozen=True, slots=True)
class OverrideRecord:
    """The audit row an accepted override calls for. SPEC.md §6.5.

    Append-only, never deletable from the app. The id and the clock are the
    caller's -- this module reads neither.
    """

    before_sen: int
    after_sen: int

    #: Trimmed, and guaranteed at least ``MIN_REASON_LENGTH`` characters.
    reason: str

    #: Never empty. The whole control is that this names somebody.
    admin_user_id: str

    @property
    def delta_sen(self) -> int:
        """What the line moved by. Negative when the override brought it down."""
        return self.after_sen - self.before_sen


@dataclass(frozen=True, slots=True)
class OverrideDecision:
    """The outcome of asking to override a line."""

    record: OverrideRecord | None = None
    refused_because: OverrideRefusal | None = None

    @property
    def is_applied(self) -> bool:
        return self.record is not None


def override_line_price(
    *,
    before_sen: int,
    after_sen: int,
    reason: str | None,
    admin_user_id: str | None,
    is_admin: bool,
    order_is_terminal: bool,
) -> OverrideDecision:
    """Decide whether a line's total may be moved by hand, and to what.

    ``admin_user_id`` is the signed-in user, ``None`` when nobody is.
    ``is_admin`` is their role. Both are needed and neither is enough: the role
    decides whether the power exists, the id decides whether the log can name
    who used it.

    ``order_is_terminal`` is ``OrderStatus.is_terminal`` for the order the line
    belongs to, passed in rather than imported so this module stays independent
    of the state machine.
    """
    # Authority first. Somebody who may not do this at all should be told that,
    # not sent off to write a longer reason for a refusal already certain.
    if not is_admin or not admin_user_id:
        return OverrideDecision(refused_because=OverrideRefusal.NOT_AN_ADMIN)

    if order_is_terminal:
        return OverrideDecision(refused_because=OverrideRefusal.ORDER_FINISHED)

    given = (reason or "").strip()
    if len(given) < MIN_REASON_LENGTH:
        return OverrideDecision(refused_because=OverrideRefusal.NO_REASON)

    if after_sen < 0:
        return OverrideDecision(refused_because=OverrideRefusal.NEGATIVE_TOTAL)

    if after_sen == before_sen:
        return OverrideDecision(refused_because=OverrideRefusal.NO_CHANGE)

    return OverrideDecision(
        record=OverrideRecord(
            before_sen=before_sen,
            after_sen=after_sen,
            reason=given,
            admin_user_id=admin_user_id,
        )
    )

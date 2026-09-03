"""Issuing order numbers. §6.3, and CLAUDE.md on IDs.

    IDs are client-generated UUID v4 ... Server-issued exceptions: payment
    receipt numbers and anything on a legal document -- null until sync, shown
    as "pending sync", **never fabricated on-device**.

§6.3 writes ``order_no`` into the schema with a note that this "deviates from
the column comment as originally written, deliberately". The reason is the same
one that governs receipt numbers: ``{branch}-{yymm}-{seq}`` has no per-device
component, so two part-timers offline at one fair would both mint
``MLK-2608-0007``, and it goes on a document the customer takes away.

The order's **id** stays a client-generated UUID, so nothing waits on a server
to exist. Only the number does, and the device shows "pending sync" until it
arrives.

Format: ``MLK-2608-0001`` -- branch, period, then a counter that restarts each
month per branch. Opening a second branch must not renumber the first.
"""

from __future__ import annotations

import re
from datetime import date

from sqlalchemy.orm import Session

from ..models.db import OrderCounter

#: Digits in the sequence. Four gives 9,999 orders per branch per month; the
#: format widens rather than wrapping if that is ever exceeded, because a
#: repeated order number is worse than an ugly one.
_WIDTH = 4

#: Letters and digits only, and short enough to read down a phone. Anything
#: else would end up in the middle of an identifier on a printed document.
_BRANCH = re.compile(r"^[A-Z0-9]{2,6}$")

#: §13 C3 is unanswered -- "One branch or several?" -- so there is one, and it
#: is named rather than assumed. When the answer arrives this becomes a lookup
#: and every number already issued still parses.
DEFAULT_BRANCH = "MLK"


class BadBranchCode(ValueError):
    """A branch code that cannot go on a printed document."""


def period_of(when: date) -> str:
    """``YYYYMM``, in whatever zone the caller has already resolved.

    Taken from the order's own confirmation time rather than from now: an order
    confirmed on the last night of a fair and synced the next morning belongs
    to the month the deposit was taken in.
    """
    return f"{when.year:04d}{when.month:02d}"


def issue_order_no(
    session: Session, *, confirmed_at: date, branch: str = DEFAULT_BRANCH
) -> str:
    """The next number for this branch in the period ``confirmed_at`` falls in.

    Locks the counter row for the duration of the transaction, so two devices
    syncing at the same instant cannot be handed the same number. On SQLite the
    lock is the whole database, which is the same guarantee by a blunter route.
    """
    if not _BRANCH.match(branch):
        raise BadBranchCode(
            f'"{branch}" is not a branch code: two to six capitals or digits'
        )

    period = period_of(confirmed_at)
    key = f"{branch}:{period}"

    row = session.get(OrderCounter, key, with_for_update=True)
    if row is None:
        row = OrderCounter(key=key, next_value=1)
        session.add(row)
        session.flush()

    value = row.next_value
    row.next_value = value + 1
    session.flush()

    # The last two digits of the year plus the month: 2608 reads as "August
    # 2026" to anybody holding the paperwork.
    return f"{branch}-{period[2:]}-{value:0{_WIDTH}d}"

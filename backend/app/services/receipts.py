"""Issuing receipt numbers. §6.4, and CLAUDE.md on IDs.

    IDs are client-generated UUID v4 ... Server-issued exceptions: payment
    receipt numbers and anything on a legal document -- null until sync, shown
    as "pending sync", **never fabricated on-device**.

So this is the one number in the system a device may not invent. Two part-timers
offline at one fair would produce the same one, and it goes on paper a customer
keeps.

Format: ``R2608-0001`` -- period, then a counter that restarts each month. Short
enough to read down a phone, long enough to be unambiguous, and sortable.
"""

from __future__ import annotations

from datetime import date

from sqlalchemy.orm import Session

from ..models.db import ReceiptCounter

#: Digits in the sequence part. Four gives 9,999 receipts in a month; the
#: format widens rather than wrapping if a month ever exceeds that, because a
#: repeated receipt number is worse than an ugly one.
_WIDTH = 4


def period_of(when: date) -> str:
    """``YYYYMM``, in whatever zone the caller has already resolved.

    Taken from the payment's own timestamp rather than from now: a payment
    taken on the last night of a fair and synced the next morning belongs to
    the month it happened in.
    """
    return f"{when.year:04d}{when.month:02d}"


def issue_receipt_no(session: Session, *, taken_at: date) -> str:
    """The next number for the period ``taken_at`` falls in.

    Locks the counter row for the duration of the transaction, so two devices
    syncing at the same instant cannot be handed the same number. On SQLite the
    lock is the whole database, which is the same guarantee by a blunter route.
    """
    period = period_of(taken_at)

    row = session.get(ReceiptCounter, period, with_for_update=True)
    if row is None:
        row = ReceiptCounter(period=period, next_value=1)
        session.add(row)
        session.flush()

    value = row.next_value
    row.next_value = value + 1
    session.flush()

    # The month is the last two digits of the year plus the month: R2608 reads
    # as "August 2026" to anybody holding the receipt.
    short_period = period[2:]
    return f"R{short_period}-{value:0{_WIDTH}d}"

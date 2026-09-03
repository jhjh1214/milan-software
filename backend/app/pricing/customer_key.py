"""Which customer a rate lock belongs to. SPEC.md §6.1 and §13 B9.

Mirrors ``mobile/lib/pricing/customer_key.dart`` decision for decision, held
together by ``shared/pricing-fixtures.json`` under ``customer_key_cases``. A
lock granted on a handset and a lock read back from the server have to agree
about whose it is, or a customer gets somebody else's held prices -- or, worse
and more quietly, loses their own.

    The lock is on **customer + category**, not on the order.

The point of a twelve-month hold is that the customer comes back, with a *new
quote*. The key has to survive that, and it did not: it was the quote id, so
the hold could never match again. The customer paid RM300 at the fair, returned
in March, and was quoted the standard rate -- more than the hold they bought.

There is no ``customers`` table yet (§13 B9 is blocking), and a quote carries a
free-text name and phone. The phone is what the shop actually collects, and
keying on it errs in the direction the customer paid for.

The normalisation is deliberately narrow, because merging two customers hands
one of them the other's prices: strip the punctuation people type, read a
``+60`` or ``60`` prefix as a leading zero, and require at least nine digits.
Anything shorter is no phone at all rather than a key, and the quote id is used
instead -- which is exactly the old behaviour, so a walk-in is no worse off.

Pure. No clock read, no I/O, no ORM.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: The shortest string that can be a Malaysian phone number. An ``03`` landline
#: is nine digits including its zero; a mobile is ten or eleven. Below nine is a
#: fragment.
MIN_PHONE_DIGITS = 9

_NOT_DIGITS = re.compile(r"[^0-9]")


@dataclass(frozen=True, slots=True)
class CustomerKey:
    """Which customer a lock belongs to, and whether the phone gave it."""

    #: Prefixed so the two kinds can never collide: a quote id that happened to
    #: look like a phone number would otherwise be one.
    value: str

    #: False when there was no usable phone and the quote id was used instead.
    from_phone: bool

    def __str__(self) -> str:
        return self.value


def normalise_phone(raw: str | None) -> str | None:
    """A phone reduced to digits, or ``None`` when what is left is not a phone.

    Returns ``None`` rather than a best guess. A key built from four digits
    would match every other four-digit fragment, and the cost of that is one
    customer being given another's prices.
    """
    if raw is None:
        return None

    digits = _NOT_DIGITS.sub("", raw)
    if not digits:
        return None

    # `+60 12...` and `60 12...` are the same number as `012...`.
    #
    # A local number is safe from this without a second guard: `060...` starts
    # with `06`, not `60`, so it is never rewritten. An earlier version added a
    # `not digits.startswith("0")` clause to protect it, which reads as though
    # it does something and cannot -- mutation testing found it was dead. The
    # case is still in the fixtures, because the property is worth pinning even
    # though it falls out of the prefix rather than out of a check.
    local = "0" + digits[2:] if digits.startswith("60") else digits

    return local if len(local) >= MIN_PHONE_DIGITS else None


def customer_key_for(*, phone: str | None, quote_id: str) -> CustomerKey:
    """The key a lock is stored and looked up under."""
    normalised = normalise_phone(phone)
    if normalised is None:
        return CustomerKey(value=f"quote:{quote_id}", from_phone=False)
    return CustomerKey(value=f"phone:{normalised}", from_phone=True)

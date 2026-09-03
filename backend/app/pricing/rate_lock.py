"""Which rate card and which discount a line is priced at. SPEC.md §6.1.

Mirrors ``mobile/lib/pricing/rate_lock.dart`` decision for decision, and the two
are held together by ``shared/pricing-fixtures.json`` under ``rate_lock_cases``
-- written before either implementation, as §6.1 asks.

The lock is on **customer plus category**, never on the order. One order can
carry curtain lines at held promo rates and flooring lines at standard price,
because only one RM300 was paid.

    Hard rule. A line whose category has no active lock must not be priced at a
    held version. *Silently applying a curtain lock to a flooring line is the
    expensive bug in this design.*

Three cases, and SPEC.md says plainly: **do not collapse them.**

1. an active lock for this line's category -- the held version and the held
   percentage, both pinned at deposit time
2. no lock, but the order came from a fair -- today's card and today's promo
3. anything else -- the version the order was pinned to, and no discount

Pure. No clock read, no I/O, no ORM: ``today`` and the locks are passed in.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from enum import Enum
from fractions import Fraction

from .models import DepositCategory, Family, deposit_category_of


class Channel(Enum):
    """Where an order came from. Every report segments by it (§3)."""

    SHOWROOM = "showroom"
    HOME_VISIT = "home_visit"
    FAIR = "fair"
    REFERRAL = "referral"
    PHONE = "phone"


class LockStatus(Enum):
    """The life of an RM300 hold."""

    ACTIVE = "active"
    EXPIRED = "expired"
    CANCELLED = "cancelled"
    REFUNDED = "refunded"


class RateSource(Enum):
    """Where a line's price came from.

    Named rather than inferred from the version, because the three cases are
    the thing that must not be collapsed -- and a test that can only compare
    version numbers cannot tell case 2 from case 1 when they happen to agree.
    """

    HELD = "held"
    FAIR_CURRENT = "fair_current"
    STANDARD_PINNED = "standard_pinned"


@dataclass(frozen=True)
class CategoryLock:
    """One RM300, holding one category's prices for twelve months."""

    id: str
    category: DepositCategory
    #: Pinned at deposit time, together with ``held_discount_pct``. Pinning only
    #: the version would silently reprice this customer when the promo moves.
    held_rate_card_version: int
    held_discount_pct: Fraction
    #: The **last day** the hold is good for, inclusive. A customer who arrives
    #: on that day was promised that price.
    held_until: date
    status: LockStatus = LockStatus.ACTIVE

    def is_active_on(self, today: date) -> bool:
        """Status and date both checked here.

        A cancelled row whose date has not passed is still not a price, and an
        active row whose date has is not either -- the nightly job that flips
        ``active`` to ``expired`` may not have run.
        """
        return self.status is LockStatus.ACTIVE and today <= self.held_until


@dataclass(frozen=True)
class RateBasis:
    """What a line is priced at, and why."""

    source: RateSource
    rate_card_version: int
    discount_pct: Fraction
    #: The lock that decided it, or None when nothing did. Written onto the
    #: order line so a price can still be explained a year later.
    lock_id: str | None = None

    @property
    def is_held(self) -> bool:
        return self.source is RateSource.HELD


def resolve_rate_basis(
    *,
    family: Family,
    locks: list[CategoryLock],
    channel: Channel,
    current_rate_card_version: int,
    current_promo_pct: Fraction,
    order_pinned_rate_card_version: int,
    today: date,
    deposit_category_override: DepositCategory | None = None,
    parent_family: Family | None = None,
) -> RateBasis:
    """Decides the card and the discount for one line. SPEC.md §6.1.

    ``locks`` is every lock the **customer** holds, not the order -- a hold
    bought at last August's fair prices a line added in the showroom in March.
    """
    category = deposit_category_override or deposit_category_of(
        family, parent_family=parent_family
    )

    # Case 1. Only a lock on THIS category counts. Searching by category rather
    # than taking the first active lock is the whole hard rule.
    for lock in locks:
        if lock.category is category and lock.is_active_on(today):
            return RateBasis(
                source=RateSource.HELD,
                rate_card_version=lock.held_rate_card_version,
                discount_pct=lock.held_discount_pct,
                lock_id=lock.id,
            )

    # Case 2. At a fair, before any RM300 is paid. Fair prices today; nothing is
    # held, so the customer walks away with a price that is not promised.
    if channel is Channel.FAIR:
        return RateBasis(
            source=RateSource.FAIR_CURRENT,
            rate_card_version=current_rate_card_version,
            discount_pct=current_promo_pct,
        )

    # Case 3. "Showroom pays standard" (§3). The order's own pinned version, so
    # a publish halfway through an order cannot move a price the customer has
    # already been shown, and never a promo percentage -- promo is fair-only.
    return RateBasis(
        source=RateSource.STANDARD_PINNED,
        rate_card_version=order_pinned_rate_card_version,
        discount_pct=Fraction(0),
    )

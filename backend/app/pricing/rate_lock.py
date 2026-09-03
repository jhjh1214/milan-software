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

from calendar import monthrange
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


class LockRefusal(Enum):
    """Why an RM300 did not open a lock."""

    #: Not taken at a fair. Client, Sep 2026: "no second rm300 paid later in
    #: showroom, only depo at fair can lock price."
    NOT_A_FAIR = "not_a_fair"
    #: Less than the configured deposit. RM250 is not RM300.
    BELOW_MINIMUM = "below_minimum"


@dataclass(frozen=True)
class LockGrant:
    """The outcome of trying to open a lock: the row, or why there is none."""

    lock: CategoryLock | None = None
    refused_because: LockRefusal | None = None

    @property
    def granted(self) -> bool:
        return self.lock is not None


def twelve_months_from(deposit_date: date) -> date:
    """The last day a hold taken on ``deposit_date`` is good for.

    The same day of the month, twelve months on, **clamped to the end of the
    month**. 29 February has no anniversary, so a leap-day deposit runs to 28
    February -- what a calendar does with a monthly anniversary, and what a
    person reading "12 months" would say.
    """
    year = deposit_date.year + 1
    month = deposit_date.month
    last_day = monthrange(year, month)[1]
    return date(year, month, min(deposit_date.day, last_day))


def open_category_lock(
    *,
    id: str,
    channel: Channel,
    category: DepositCategory,
    deposit_date: date,
    deposit_sen: int,
    min_deposit_sen: int,
    rate_card_version: int,
    promo_pct: Fraction,
) -> LockGrant:
    """Opens a category lock, or explains why it cannot. SPEC.md §6.1, §13 B1.

    **The only place a ``category_locks`` row is created.** Both rules live here
    rather than on the screen that collects the money, so a screen that forgets
    one cannot bypass it:

    - **Only a fair.** A showroom, home-visit, phone or referral deposit
      confirms an order and buys nothing else. There is no way to acquire held
      prices after the fair has packed up.
    - **The full RM300.** Checked here rather than trusted from the caller: a
      partial payment must not buy a full twelve-month hold.

    ``promo_pct`` is pinned alongside the version, because pinning only the
    version silently reprices this customer when the promo moves.
    """
    if channel is not Channel.FAIR:
        return LockGrant(refused_because=LockRefusal.NOT_A_FAIR)
    if deposit_sen < min_deposit_sen:
        return LockGrant(refused_because=LockRefusal.BELOW_MINIMUM)

    return LockGrant(
        lock=CategoryLock(
            id=id,
            category=category,
            held_rate_card_version=rate_card_version,
            held_discount_pct=promo_pct,
            held_until=twelve_months_from(deposit_date),
            status=LockStatus.ACTIVE,
        )
    )

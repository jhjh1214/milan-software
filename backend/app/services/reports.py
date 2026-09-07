"""The four reports SPEC.md §11 Phase 5 asks for.

    Reports — estimate vs final variance by salesperson, fair performance,
    outstanding balances aged, declined category deposits

Three of them are here. The fourth, declined category deposits, is already
served raw by `reads.prompts_between`: the counting is trivial and the office
wants to slice it by salesperson and by fair, so aggregating it here would mean
two summaries that have to agree and eventually will not.

**Money never leaves this module as anything but integer sen**, and there is
deliberately no average anywhere in it. An average of sen needs a rounding rule,
and inventing one to make a screen look tidy is how a rounding rule ends up
being used for something that matters.

**Nothing is called overdue.** The system has no invoice date and no payment
terms, so it cannot know when a balance falls due. What it can say is how long
it has been since the deposit was taken, and that is what it says (§13 C11).

**The variance report subtracts nothing.** §6.3 wants it to show who is guessing
badly, and CLAUDE.md warns that a quotation rounds every quantity up while the
final bill uses the exact tape -- so every honest estimate comes in high and the
whole column is biased in one direction. The bias is left in and named, because
removing it here would mean choosing a correction factor, and that is a business
decision nobody has made. What is *not* averaged away is an order whose final
came out **above** its estimate: §8.5 says that cannot happen, so it is counted
on its own and never netted off against the orders that behaved.

PURE of HTTP, and the clock is injected.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..api.schemas import (
    AgeingBucket,
    BalancesReport,
    FairPerformance,
    FairReport,
    OutstandingBalance,
    SalespersonVariance,
    VarianceReport,
)
from ..models.db import CategoryLock, Order, RateCardVersion, User

#: Statuses where a balance is still money somebody expects to collect.
#:
#: `closed` is finished. `cancelled` is excluded because what happens to a
#: cancelled order's deposit is §13 B3, unanswered -- reporting a balance for one
#: would be this module answering a money question that nobody has asked the
#: client yet.
OWING_STATUSES: tuple[str, ...] = (
    "confirmed",
    "measurement_booked",
    "measured",
    "material_selected",
    "in_production",
    "ready",
    "installed",
)

#: Days since the deposit. The 30/60/90 shape is the ordinary accounting one,
#: so a bookkeeper reads it without being taught; the label says "since deposit"
#: because that is the only date the system actually knows.
#: Half-open day ranges, ``[low, high)``. Numbers rather than labels: the
#: dashboard speaks three languages (SPEC.md 13 C9) and the words belong to
#: whichever one the reader has chosen, not to this file.
BUCKETS: tuple[tuple[int, int | None], ...] = (
    (0, 31),
    (31, 61),
    (61, 91),
    (91, None),
)


def _utc(value: datetime) -> datetime:
    """The same instant, guaranteed to carry a timezone.

    Postgres returns an aware datetime from a `timestamptz`; SQLite, which the
    fast tests run against, returns a naive one. Everything here is stored UTC,
    so attaching it back is restoring what the column already meant.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def _whole_days(frm: datetime, to: datetime) -> int:
    """Whole days between two instants, never negative.

    A handset's clock can be ahead of the server's. "-2 days" in an ageing
    column reads as a broken report rather than as one phone's wrong clock.
    """
    return max(0, (_utc(to) - _utc(frm)).days)


def variance_by_salesperson(session: Session) -> VarianceReport:
    """Estimate against tape, per salesperson. §6.3, §11 Phase 5.

    Empty until Phase 6 sets a final price on anything, and it says so rather
    than returning a bare empty table -- which is indistinguishable from a
    query that failed.
    """
    orders = list(session.scalars(select(Order).where(Order.status != "cancelled")))
    names = dict(session.execute(select(User.id, User.name)).all())

    priced: dict[str | None, list[Order]] = defaultdict(list)
    awaiting: dict[str | None, int] = defaultdict(int)
    for order in orders:
        who = order.confirmed_by_user_id
        if order.final_total_sen is None:
            awaiting[who] += 1
        else:
            priced[who].append(order)

    rows = []
    for who in sorted(set(priced) | set(awaiting), key=lambda k: (k is None, k or "")):
        mine = priced[who]
        estimate = sum(o.estimate_total_sen for o in mine)
        final = sum(o.final_total_sen or 0 for o in mine)
        rows.append(
            SalespersonVariance(
                user_id=who,
                name=names.get(who) if who is not None else None,
                orders_priced=len(mine),
                orders_awaiting_final=awaiting[who],
                estimate_total_sen=estimate,
                final_total_sen=final,
                variance_sen=final - estimate,
                # Counted, never netted off. §8.5 promises the final will be
                # the same or lower, so one of these is a broken promise rather
                # than a bad guess, and averaging it against the orders that
                # behaved would hide exactly the thing worth seeing.
                orders_over_estimate=sum(
                    1 for o in mine if (o.final_total_sen or 0) > o.estimate_total_sen
                ),
            )
        )

    return VarianceReport(
        rows=rows,
        nothing_priced_yet=not any(row.orders_priced for row in rows),
    )


def _promo_by_version(
    session: Session,
) -> dict[int, tuple[str | None, str | None, str | None]]:
    """Each published card version's promo code and window.

    Read out of the stored payload rather than from columns of its own. §9.1
    keeps the card whole because the device replaces it wholesale, and shredding
    it into columns here would create a second copy to keep in step.
    """
    rows = session.execute(
        select(RateCardVersion.version, RateCardVersion.payload)
    ).all()

    found: dict[int, tuple[str | None, str | None, str | None]] = {}
    for version, payload in rows:
        promo = (payload or {}).get("promo") or {}
        found[version] = (
            promo.get("code"),
            promo.get("valid_from"),
            promo.get("valid_to"),
        )
    return found


def fair_performance(session: Session) -> FairReport:
    """What each fair did. §11 Phase 5.

    Grouped on the promo code of the card an order pinned. `channel = 'fair'`
    says an order came from a fair; the pinned version says **which** one, and
    that is the grouping somebody comparing August to next February needs.

    A fair-channel order pinned to a card with no promo is its own row rather
    than being dropped. It is a real order and hiding it would make the totals
    disagree with the order board.
    """
    promos = _promo_by_version(session)

    orders = list(
        session.scalars(
            select(Order).where(
                Order.channel == "fair",
                Order.status != "cancelled",
            )
        )
    )

    #: Holds are attributed by the version they pinned, not by when they were
    #: opened: a deposit taken on the last afternoon and synced the next
    #: morning belongs to the fair it was taken at.
    lock_counts: dict[str | None, int] = defaultdict(int)
    for version in session.scalars(select(CategoryLock.held_rate_card_version)):
        lock_counts[promos.get(version, (None, None, None))[0]] += 1

    grouped: dict[str | None, list[Order]] = defaultdict(list)
    for order in orders:
        grouped[
            promos.get(order.pinned_rate_card_version, (None, None, None))[0]
        ].append(order)

    windows = {code: (frm, to) for code, frm, to in promos.values()}

    fairs = []
    for code in sorted(grouped, key=lambda c: (c is None, c or "")):
        mine = grouped[code]
        frm, to = windows.get(code, (None, None))
        fairs.append(
            FairPerformance(
                promo_code=code,
                valid_from=frm,
                valid_to=to,
                orders=len(mine),
                estimate_total_sen=sum(o.estimate_total_sen for o in mine),
                deposits_taken_sen=sum(o.deposit_paid_sen for o in mine),
                locks_opened=lock_counts.get(code, 0),
            )
        )

    return FairReport(fairs=fairs)


def outstanding_balances(session: Session, *, now: datetime) -> BalancesReport:
    """Money still to come, aged by how long since the deposit. §11 Phase 5.

    The total is the final price where one exists and the **estimate** where one
    does not, and every row says which. §8.5 makes an estimate an upper bound --
    the final will be the same or lower, never higher -- so an estimated balance
    is the most that could be owed, not a debt, and a report that quietly mixed
    the two would overstate what is collectable.

    Sorted oldest first: the row at the top is the one that has been waiting
    longest, which is the one somebody should be phoning about.
    """
    orders = list(
        session.scalars(
            select(Order)
            .where(Order.status.in_(OWING_STATUSES))
            .order_by(Order.confirmed_at)
        )
    )

    balances = []
    for order in orders:
        final = order.final_total_sen
        total = order.estimate_total_sen if final is None else final
        balance = total - order.deposit_paid_sen
        # A deposit larger than the total leaves nothing to collect. Reported
        # as nothing owing rather than as a negative balance: what to do about
        # the difference is a refund question, and this report does not answer
        # money questions.
        if balance <= 0:
            continue

        balances.append(
            OutstandingBalance(
                order_id=order.id,
                order_no=order.order_no,
                customer_name=order.customer_name,
                customer_phone=order.customer_phone,
                status=order.status,
                confirmed_at=_utc(order.confirmed_at),
                days_since_deposit=_whole_days(order.confirmed_at, now),
                total_sen=total,
                deposit_paid_sen=order.deposit_paid_sen,
                balance_sen=balance,
                is_estimate=final is None,
            )
        )

    buckets = [
        AgeingBucket(
            days_from=low,
            days_to=high,
            orders=len(rows),
            balance_sen=sum(row.balance_sen for row in rows),
        )
        for low, high, rows in (
            (low, high, _in_bucket(balances, low, high)) for low, high in BUCKETS
        )
    ]

    return BalancesReport(
        balances=balances,
        buckets=buckets,
        total_balance_sen=sum(row.balance_sen for row in balances),
        estimated_balance_sen=sum(
            row.balance_sen for row in balances if row.is_estimate
        ),
    )


def _in_bucket(
    rows: list[OutstandingBalance], low: int, high: int | None
) -> list[OutstandingBalance]:
    """Rows aged into `[low, high)`. Half-open, so one order lands in exactly
    one bucket rather than in two or in neither -- the same window the weekly
    override review uses."""
    return [
        row
        for row in rows
        if row.days_since_deposit >= low
        and (high is None or row.days_since_deposit < high)
    ]

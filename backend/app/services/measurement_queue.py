"""What is waiting for a site visit. SPEC.md §11 Phase 5.

    Measurement queue — grouped by project so one trip covers several units

**§13 C10, answered: zone first, then customer.** There is still no project
library entry for most orders -- a fair walk-in never gets a `project_id` at
all -- and no *street-level* address is captured anywhere before a visit (the
only address on `Order` is written after measurement, for invoicing, which is
too late to plan the trip that produces it). But every order already carries
a `delivery_zone_id`, picked at quote time from the small fixed set of zones
on the active rate card -- real data, already on essentially every order,
just never used for this. So a trip is grouped by zone first, then by
customer within the zone, keyed on the normalised phone exactly as a rate
lock is (§13 B9). An order with no zone lands in its own "unzoned" bucket
rather than being guessed into one. True taman-level grouping stays open,
blocked on capturing a real address before the visit -- see the write-up
alongside this answer.

**Which orders are in it.** Everything at `confirmed` or `measurement_booked`.
Not "everything with unmeasured lines": §13 C7 is unanswered, so the pipeline
refuses to skip the measurement steps, and an order with nothing left to measure
still needs somebody to walk it through them. Filtering on the unmeasured count
would make exactly those orders invisible and they would sit at `confirmed`
forever, which is the failure nobody would notice.

**Ordered by whose deadline is nearest, and grouped so one drive covers an
area** (client, Sep 2026). Visits used to be booked one appointment at a
time, which sent somebody back and forth to the same taman all month. Now:

- **Every order has a deadline.** A customer holding a fair price (§6.1) has
  that hold's expiry; anyone else has twelve months from their deposit, the
  fulfilment window every order carries (§3). Among orders with no hold that
  is exactly "who has waited longest"; a hold ending sooner puts its
  customer ahead of them.
- **Trips group into areas** by postcode when the order has one, otherwise
  by delivery zone, so nothing disappears while an address is still being
  collected. An area sorts by the most urgent order inside it: the first
  trip is the one to call first, and every other trip in its area is one to
  book for the same day.
- **A house not ready yet** (a future `site_ready_from`, keys not handed
  over) is listed apart, soonest-ready first, and never anchors a day --
  phoning a customer who can only say "not yet" wastes the call.

PURE of HTTP, and the clock is injected. `waiting_days` is a number somebody
reads off a screen and a test has to be able to pin it.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import UTC, date, datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..api.schemas import MeasurementGroup, MeasurementJob, MeasurementQueueOut
from ..models.db import CategoryLock, Order, OrderEvent, OrderLine
from ..pricing.customer_key import customer_key_for
from ..pricing.rate_lock import twelve_months_from

#: The two stages a site visit is still outstanding at. `measured` and
#: everything after it has had its tape taken; `cancelled` is not a trip.
WAITING_STATUSES: tuple[str, ...] = ("confirmed", "measurement_booked")

#: The event written when a visit is booked -- the target status's wire value,
#: which is what both `advance_order` implementations record.
BOOKED_EVENT = "measurement_booked"

#: The bucket for an order with no delivery zone recorded. Never merged with
#: a real zone -- a missing zone is a fact worth showing, not hiding.
UNZONED = "unzoned"

#: Malaysia's clock. A fixed UTC+8 rather than a tz database lookup: the
#: country has not observed daylight saving since 1982, and the slim image
#: ships no tz database for `zoneinfo` to read. Used only to say what day it
#: is for "days left" and "ready from".
MALAYSIA = timezone(timedelta(hours=8))


def _zone_key(order: Order) -> str:
    """Which zone groups this order, or the unzoned bucket.

    `delivery_zone_id` is picked at quote time, before a visit is ever
    scheduled, from the small fixed set of zones on the active rate card --
    unlike a street address, it already exists on essentially every order.
    """
    return order.delivery_zone_id or UNZONED


def _trip_key(order: Order) -> tuple[str, bool]:
    """What groups this order into a trip, and whether a phone produced it.

    The same normalisation a rate lock uses, never the raw phone: a customer who
    typed `012-345 6789` on one visit and `0123456789` on the next is one trip,
    and treating them as two is the bug this area already had once.

    With no usable phone the order is its own group. Pooling every phone-less
    order together would invent a trip that does not exist and send somebody
    across Melaka for it.
    """
    key = customer_key_for(phone=order.customer_phone, quote_id=order.quote_id)
    if key.from_phone:
        return key.value, True
    return f"order:{order.id}", False


def _utc(value: datetime) -> datetime:
    """The same instant, guaranteed to carry a timezone.

    Every timestamp in this system is stored UTC, but what comes back depends
    on the driver: Postgres returns an aware datetime from a `timestamptz` and
    SQLite -- which the fast tests run against -- returns a naive one. Attaching
    UTC to a naive value is therefore not a guess, it is restoring what the
    column already meant.

    Without this, subtracting a stored time from an injected `now` raises on
    SQLite and silently works on Postgres, which is the worst arrangement of
    the two.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def _whole_days(frm: datetime, to: datetime) -> int:
    """Whole days between two instants, never negative.

    A device's clock can be ahead of the server's, so a deposit can arrive
    stamped in the future. "-2 days waiting" on a screen is worse than "0": it
    reads as a bug in the queue rather than a bug in one handset's clock.
    """
    return max(0, (_utc(to) - _utc(frm)).days)


def _area_of(order: Order) -> tuple[str, str | None]:
    """Which area groups this order's trip, and its postcode if it has one."""
    if order.site_postcode:
        return f"postcode:{order.site_postcode}", order.site_postcode
    return _zone_key(order), None


def _local_day(value: datetime) -> date:
    return _utc(value).astimezone(MALAYSIA).date()


def measurement_queue(
    session: Session,
    *,
    now: datetime,
    zone_labels: Mapping[str, dict[str, str]] | None = None,
) -> MeasurementQueueOut:
    """Every order waiting for a site visit, grouped into trips and areas.

    `zone_labels` maps a `delivery_zone_id` to its `{zh, en, ms}` label map,
    read from the active rate card's own `delivery_zones` -- injected rather
    than loaded in here, the same "pure of HTTP" reason the clock is. A zone
    id with no entry (a stale reference to a zone since renamed, or no card
    resolved at all) still groups correctly; it just shows its raw id instead
    of a label, never a crash.
    """
    zone_labels = zone_labels or {}
    today = _local_day(now)
    orders = list(
        session.scalars(
            select(Order)
            .where(Order.status.in_(WAITING_STATUSES))
            .order_by(Order.confirmed_at)
        )
    )
    if not orders:
        return MeasurementQueueOut()

    ids = [order.id for order in orders]
    counts = _line_counts(session, ids)
    booked = _booked_at(session, ids)
    holds = _hold_ends(session, orders)

    ready: dict[str, MeasurementGroup] = {}
    waiting: dict[str, MeasurementGroup] = {}
    for order in orders:
        zone_id = _zone_key(order)
        area_key, postcode = _area_of(order)
        phone_key, from_phone = _trip_key(order)
        total, unmeasured, pending = counts.get(order.id, (0, 0, 0))

        hold_end = holds.get(phone_key) if from_phone else None
        deadline = (
            hold_end
            if hold_end is not None
            else twelve_months_from(_local_day(order.confirmed_at))
        )
        job = MeasurementJob(
            order_id=order.id,
            order_no=order.order_no,
            status=order.status,
            channel=order.channel,
            line_count=total,
            unmeasured_line_count=unmeasured,
            material_pending_count=pending,
            estimate_total_sen=order.estimate_total_sen,
            confirmed_at=_utc(order.confirmed_at),
            booked_at=booked.get(order.id),
            waiting_days=_whole_days(order.confirmed_at, now),
            site_address_note=order.site_address_note,
            site_postcode=order.site_postcode,
            site_ready_from=order.site_ready_from,
            deadline=deadline,
            days_left=(deadline - today).days,
            deadline_from_hold=hold_end is not None,
        )

        not_yet = order.site_ready_from is not None and order.site_ready_from > today
        groups = waiting if not_yet else ready
        key = f"{area_key}:{phone_key}"
        group = groups.get(key)
        if group is None:
            groups[key] = MeasurementGroup(
                key=key,
                customer_name=order.customer_name,
                customer_phone=order.customer_phone,
                grouped_by_phone=from_phone,
                delivery_zone_id=None if zone_id == UNZONED else zone_id,
                delivery_zone_labels=zone_labels.get(zone_id),
                jobs=[job],
                # Orders arrive oldest first, so the first one into a group is
                # the oldest in it.
                oldest_confirmed_at=_utc(order.confirmed_at),
                waiting_days=job.waiting_days,
                booked_count=1 if order.status == BOOKED_EVENT else 0,
                area_key=area_key,
                site_postcode=postcode,
                deadline=deadline,
                days_left=job.days_left,
            )
            continue

        group.jobs.append(job)
        if order.status == BOOKED_EVENT:
            group.booked_count += 1
        # A later order can carry a name where the first had none. Taking it
        # beats showing a trip with no name on it.
        if group.customer_name is None:
            group.customer_name = order.customer_name
        if deadline < group.deadline:
            group.deadline = deadline
            group.days_left = job.days_left

    for group in [*ready.values(), *waiting.values()]:
        group.jobs.sort(key=lambda j: (j.deadline, j.confirmed_at))

    # An area's position is its most urgent trip's deadline, never its key --
    # so clustering by area can never bury an urgent customer behind an area
    # that merely sorts earlier. Within the area, most urgent trip first.
    area_deadline: dict[str, date] = {}
    for g in ready.values():
        current = area_deadline.get(g.area_key)
        if current is None or g.deadline < current:
            area_deadline[g.area_key] = g.deadline

    ordered = sorted(
        ready.values(),
        key=lambda g: (
            area_deadline[g.area_key],
            g.area_key,
            g.deadline,
            g.oldest_confirmed_at,
            g.key,
        ),
    )

    def ready_on(g: MeasurementGroup) -> date:
        return min(j.site_ready_from for j in g.jobs if j.site_ready_from)

    not_ready = sorted(waiting.values(), key=lambda g: (ready_on(g), g.deadline, g.key))
    return MeasurementQueueOut(
        groups=ordered,
        not_ready=not_ready,
        total_orders=len(orders),
        missing_postcode_count=sum(1 for o in orders if not o.site_postcode),
    )


def _hold_ends(session: Session, orders: list[Order]) -> dict[str, date]:
    """The soonest active held-price expiry per customer, in one query.

    Keyed on the same normalised phone a lock is. An order with no usable
    phone cannot be matched to a hold, which is the same answer as having
    none -- its deadline is the plain twelve-month window.
    """
    keys = {
        key.value
        for key in (
            customer_key_for(phone=o.customer_phone, quote_id=o.quote_id)
            for o in orders
        )
        if key.from_phone
    }
    if not keys:
        return {}
    rows = session.execute(
        select(CategoryLock.customer_key, func.min(CategoryLock.held_until))
        .where(
            CategoryLock.status == "active",
            CategoryLock.customer_key.in_(keys),
        )
        .group_by(CategoryLock.customer_key)
    ).all()
    return {key: _local_day(until) for key, until in rows if until is not None}


def _line_counts(
    session: Session, order_ids: list[str]
) -> dict[str, tuple[int, int, int]]:
    """Per order: lines, lines with no tape taken, materials still to choose.

    One query for the whole queue rather than one per order. Counted in SQL
    with a filtered aggregate so a fifty-line order does not travel just to be
    counted.
    """
    rows = session.execute(
        select(
            OrderLine.order_id,
            func.count(),
            func.count().filter(OrderLine.is_site_measured.is_(False)),
            func.count().filter(
                OrderLine.material_deferred.is_(True),
                OrderLine.material_key.is_(None),
            ),
        )
        .where(OrderLine.order_id.in_(order_ids))
        .group_by(OrderLine.order_id)
    ).all()
    return {row[0]: (row[1], row[2], row[3]) for row in rows}


def _booked_at(session: Session, order_ids: list[str]) -> dict[str, datetime]:
    """When each visit was booked, from the append-only history.

    `orders` has no booking column and is not getting one: the event is already
    recorded, and a column beside it would be a second truth that drifts.

    `max` is the aggregate a GROUP BY needs, not a rule for choosing between
    bookings. There is at most one such event per order today -- booking a
    second time is refused as `already_there` and writes nothing -- so there is
    nothing to choose between, and inventing a rule for a case the pipeline
    cannot produce would be building for what might exist.
    """
    rows = session.execute(
        select(OrderEvent.order_id, func.max(OrderEvent.at))
        .where(
            OrderEvent.order_id.in_(order_ids),
            OrderEvent.event == BOOKED_EVENT,
        )
        .group_by(OrderEvent.order_id)
    ).all()
    return {order_id: _utc(at) for order_id, at in rows if at is not None}

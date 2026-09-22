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

**Ordered by who has waited longest**, not by hold expiry the way the order
board is. An order pinned its rate card version when the deposit confirmed it,
so measuring it late does not reprice it -- the hold protects the customer's
*next* quote, not this one. What is actually urgent here is a person who paid a
deposit in July and has not had a phone call.

Zone clustering must never bury that urgency: a zone's own position in the
list is driven by the longest-waiting order *inside* it, not by zone id or
alphabetical order. The zone holding the most overdue customer sorts first,
so route efficiency and customer urgency point the same direction instead of
trading off against each other. Within a zone, trips keep the existing
oldest-first order.

PURE of HTTP, and the clock is injected. `waiting_days` is a number somebody
reads off a screen and a test has to be able to pin it.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..api.schemas import MeasurementGroup, MeasurementJob, MeasurementQueueOut
from ..models.db import Order, OrderEvent, OrderLine
from ..pricing.customer_key import customer_key_for

#: The two stages a site visit is still outstanding at. `measured` and
#: everything after it has had its tape taken; `cancelled` is not a trip.
WAITING_STATUSES: tuple[str, ...] = ("confirmed", "measurement_booked")

#: The event written when a visit is booked -- the target status's wire value,
#: which is what both `advance_order` implementations record.
BOOKED_EVENT = "measurement_booked"

#: The bucket for an order with no delivery zone recorded. Never merged with
#: a real zone -- a missing zone is a fact worth showing, not hiding.
UNZONED = "unzoned"


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


def measurement_queue(
    session: Session,
    *,
    now: datetime,
    zone_labels: Mapping[str, dict[str, str]] | None = None,
) -> MeasurementQueueOut:
    """Every order waiting for a site visit, grouped into trips.

    `zone_labels` maps a `delivery_zone_id` to its `{zh, en, ms}` label map,
    read from the active rate card's own `delivery_zones` -- injected rather
    than loaded in here, the same "pure of HTTP" reason the clock is. A zone
    id with no entry (a stale reference to a zone since renamed, or no card
    resolved at all) still groups correctly; it just shows its raw id instead
    of a label, never a crash.
    """
    zone_labels = zone_labels or {}
    orders = list(
        session.scalars(
            select(Order)
            .where(Order.status.in_(WAITING_STATUSES))
            .order_by(Order.confirmed_at)
        )
    )
    if not orders:
        return MeasurementQueueOut(groups=[], total_orders=0)

    ids = [order.id for order in orders]
    counts = _line_counts(session, ids)
    booked = _booked_at(session, ids)

    groups: dict[str, MeasurementGroup] = {}
    for order in orders:
        zone_id = _zone_key(order)
        phone_key, from_phone = _trip_key(order)
        key = f"{zone_id}:{phone_key}"
        total, unmeasured, pending = counts.get(order.id, (0, 0, 0))
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
        )

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
            )
            continue

        group.jobs.append(job)
        if order.status == BOOKED_EVENT:
            group.booked_count += 1
        # A later order can carry a name where the first had none. Taking it
        # beats showing a trip with no name on it.
        if group.customer_name is None:
            group.customer_name = order.customer_name

    # A zone's position is driven by the longest-waiting order it holds
    # (earliest `oldest_confirmed_at` == most overdue), never by zone id --
    # otherwise route clustering could bury an urgent customer behind a zone
    # that merely sorts earlier. Within a zone the existing oldest-first
    # order is unchanged.
    zone_urgency: dict[str, datetime] = {}
    for g in groups.values():
        zone = g.delivery_zone_id or UNZONED
        current = zone_urgency.get(zone)
        if current is None or g.oldest_confirmed_at < current:
            zone_urgency[zone] = g.oldest_confirmed_at

    ordered = sorted(
        groups.values(),
        key=lambda g: (
            zone_urgency[g.delivery_zone_id or UNZONED],
            g.oldest_confirmed_at,
            g.key,
        ),
    )
    return MeasurementQueueOut(groups=ordered, total_orders=len(orders))


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

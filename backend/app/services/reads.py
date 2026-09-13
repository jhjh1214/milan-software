"""What the dashboard reads. SPEC.md §11 Phase 5.

Every other endpoint in this service is a push. That asymmetry is why two rate
lock bugs went unnoticed for as long as they did: nothing ever read the data
back, so nothing noticed that `order_lines.category_lock_id` pointed at rows the
server had never seen.

Three things shape what is here.

**The board is a list of cards, not a list of orders.** It shows 500 at a time
and sending every line with each would make the one screen the office lives in
slow enough that people stop opening it.

**The detail view answers one question in one round trip.** Somebody looking at
an order is almost always answering "why is this number what it is", and three
requests to answer that is three chances to give up.

**Filters are explicit and total is always returned.** A board that cannot say
"50 of 512" leaves somebody guessing whether their filter did anything.

PURE of HTTP. The router calls this; the tests call it directly.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..api.schemas import (
    BuyerOut,
    DepositPromptOut,
    OrderDetailOut,
    OrderEventOut,
    OrderLineOut,
    OrderSummary,
    PriceOverrideOut,
)
from ..models.db import (
    CategoryLock,
    DepositPrompt,
    Order,
    OrderEvent,
    OrderLine,
    PriceOverride,
)
from ..pricing.customer_key import customer_key_for
from ..pricing.einvoice_threshold import (
    BuyerDetails,
    buyer_details_complete,
    missing_buyer_details,
)

#: The most cards one request will return. §11 Phase 5 wants 500 without
#: pagination lag, so the default page is the whole board and the cap exists to
#: stop a mistyped query pulling a year of orders into one response.
MAX_PAGE = 500


def _customer_key(order: Order) -> str | None:
    """The key any hold of this customer's is filed under, or None.

    Built with the same function the device uses, never from the raw phone. A
    customer who typed `012-345 6789` on one visit is keyed under
    `phone:0123456789`, and looking them up by what they typed would miss the
    hold they paid for -- which is the bug this whole area already had once.
    """
    if not order.customer_phone:
        return None
    key = customer_key_for(phone=order.customer_phone, quote_id=order.quote_id)
    # A quote-scoped key belongs to one handset's quote, not to a customer the
    # board can look up. Treated as no key at all rather than as a match.
    return key.value if key.from_phone else None


def _summary(
    order: Order, *, line_count: int, held_until: datetime | None
) -> OrderSummary:
    return OrderSummary(
        id=order.id,
        order_no=order.order_no,
        status=order.status,
        channel=order.channel,
        customer_name=order.customer_name,
        customer_phone=order.customer_phone,
        estimate_total_sen=order.estimate_total_sen,
        deposit_paid_sen=order.deposit_paid_sen,
        has_unmeasured_lines=order.has_unmeasured_lines,
        confirmed_at=order.confirmed_at,
        line_count=line_count,
        held_until=held_until,
    )


def _held_until_by_customer(
    session: Session, keys: list[str] | None = None
) -> dict[str, datetime]:
    """The soonest active hold expiry per customer key.

    **One query, whatever the page holds.** The board sorts by this and colours
    by it, so it is read for every card on screen -- and a lookup per card is
    the shape that turns a board somebody opens all day into one they stop
    opening. §11 Phase 5 wants 500 orders without pagination lag, and that is
    what this constant is protecting.

    ``keys`` scopes it to the customers actually on the page. Passing None reads
    every active hold, which is right for a single order's detail view and wrong
    for a board.
    """
    query = select(
        CategoryLock.customer_key,
        func.min(CategoryLock.held_until),
    ).where(CategoryLock.status == "active")

    if keys is not None:
        if not keys:
            return {}
        query = query.where(CategoryLock.customer_key.in_(keys))

    rows = session.execute(query.group_by(CategoryLock.customer_key)).all()
    return {key: until for key, until in rows if until is not None}


def _expiry_of(order: Order, expiries: dict[str, datetime]) -> datetime | None:
    """When this order's customer's soonest hold runs out.

    An order with no usable phone has no hold the board can find, which is the
    same answer as having no hold.
    """
    key = _customer_key(order)
    return None if key is None else expiries.get(key)


def list_orders(
    session: Session,
    *,
    status: str | None = None,
    channel: str | None = None,
    confirmed_by_user_id: str | None = None,
    confirmed_from: datetime | None = None,
    confirmed_to: datetime | None = None,
    limit: int = MAX_PAGE,
    offset: int = 0,
) -> tuple[list[OrderSummary], int]:
    """A page of the order board, and how many match the filter.

    Every filter is optional and they combine. ``confirmed_from`` is inclusive
    and ``confirmed_to`` exclusive, so one order lands in exactly one period
    rather than in two or in neither -- the same half-open window the weekly
    override review uses.

    ``confirmed_by_user_id`` is the salesperson filter named in SPEC.md §11
    Phase 5's own wishlist alongside channel -- a direct equality on a
    column this table already carries, unlike "which fair" or "which
    project", neither of which this table has a column for at all (a fair
    is only known by the promo code a *pinned rate card version* carries,
    and a project is only known through an order *line's* provenance, never
    the order itself -- both real design questions, not a filter to add
    here by guessing one).

    Sorted by ``held_until`` ascending with nulls last, then by confirmation
    date. §11 Phase 5: the board is sorted by how soon a hold runs out, because
    a hold that expires unused is a customer who paid RM300 and got nothing.
    """
    filters = []
    if status is not None:
        filters.append(Order.status == status)
    if channel is not None:
        filters.append(Order.channel == channel)
    if confirmed_by_user_id is not None:
        filters.append(Order.confirmed_by_user_id == confirmed_by_user_id)
    if confirmed_from is not None:
        filters.append(Order.confirmed_at >= confirmed_from)
    if confirmed_to is not None:
        filters.append(Order.confirmed_at < confirmed_to)

    total = session.scalar(select(func.count()).select_from(Order).where(*filters))

    orders = list(
        session.scalars(
            select(Order).where(*filters).order_by(Order.confirmed_at.desc())
        )
    )

    # Both scoped to the orders in hand rather than to the whole table. Counting
    # every line ever written to tell one page how many lines it has is work
    # that grows with the business while the screen does not.
    ids = [order.id for order in orders]
    counts = (
        dict(
            session.execute(
                select(OrderLine.order_id, func.count())
                .where(OrderLine.order_id.in_(ids))
                .group_by(OrderLine.order_id)
            ).all()
        )
        if ids
        else {}
    )
    keys = [key for key in (_customer_key(order) for order in orders) if key]
    expiries = _held_until_by_customer(session, keys)

    summaries = [
        _summary(
            order,
            line_count=counts.get(order.id, 0),
            # Matched on the phone, which is what a hold is keyed to (§13 B9).
            # An order with no phone has no hold to expire, which is the same
            # answer as "no hold".
            held_until=_expiry_of(order, expiries),
        )
        for order in orders
    ]

    # Sorted here rather than in SQL: the expiry comes from another table keyed
    # on a string this table does not hold, and a join on a derived key would be
    # the kind of clever that breaks the day the key changes. Nulls last, so an
    # order with nothing running out does not sit above one that does.
    summaries.sort(key=lambda s: (s.held_until is None, s.held_until or datetime.max))

    return summaries[offset : offset + min(limit, MAX_PAGE)], total or 0


def order_detail(session: Session, order_id: str) -> OrderDetailOut | None:
    """One order, with its lines, its history and every price moved by hand."""
    order = session.get(Order, order_id)
    if order is None:
        return None

    lines = list(
        session.scalars(
            select(OrderLine)
            .where(OrderLine.order_id == order_id)
            .order_by(OrderLine.sort_order)
        )
    )
    events = list(
        session.scalars(
            select(OrderEvent)
            .where(OrderEvent.order_id == order_id)
            .order_by(OrderEvent.at)
        )
    )
    overrides = list(
        session.scalars(
            select(PriceOverride)
            .where(PriceOverride.order_id == order_id)
            .order_by(PriceOverride.at)
        )
    )

    expiries = _held_until_by_customer(session)

    return OrderDetailOut(
        order=_summary(
            order,
            line_count=len(lines),
            held_until=_expiry_of(order, expiries),
        ),
        lines=[
            OrderLineOut(
                id=line.id,
                sort_order=line.sort_order,
                room=line.room,
                variant=line.variant,
                material_key=line.material_key,
                layer=line.layer,
                est_width_tmm=line.est_width_tmm,
                est_height_tmm=line.est_height_tmm,
                final_width_tmm=line.final_width_tmm,
                final_height_tmm=line.final_height_tmm,
                direct_area_sqft=line.direct_area_sqft,
                is_site_measured=line.is_site_measured,
                quantity=line.quantity,
                applied_rule_id=line.applied_rule_id,
                applied_band_label=line.applied_band_label,
                applied_rate_card_version=line.applied_rate_card_version,
                applied_discount_pct=line.applied_discount_pct,
                standard_rate_sen=line.standard_rate_sen,
                rate_sen=line.rate_sen,
                billed_qty=line.billed_qty,
                billed_unit=line.billed_unit,
                line_total_sen=line.line_total_sen,
                material_deferred=line.material_deferred,
                is_overridden=line.is_overridden,
            )
            for line in lines
        ],
        events=[
            OrderEventOut(
                id=event.id,
                event=event.event,
                note=event.note,
                by_user_id=event.by_user_id,
                at=event.at,
            )
            for event in events
        ],
        overrides=[_override_out(row) for row in overrides],
        buyer=_buyer_out(order),
    )


def _buyer_out(order: Order) -> BuyerOut:
    """What is on file about the buyer, plus what is still missing. §10.3.

    ``complete`` and ``missing`` are computed from the same rule the handset
    shows rather than stored beside the row. A boolean column would be a second
    answer that drifts the first time somebody edits a field without
    recomputing it -- and the thing it would be wrong about is whether a
    customer still has to be telephoned before an invoice can be issued.
    """
    buyer = BuyerDetails(
        name=order.customer_name,
        tin=order.buyer_tin,
        id_type=order.buyer_id_type,
        id_number=order.buyer_id_number,
        address_line1=order.buyer_address_line1,
        address_line2=order.buyer_address_line2,
        city=order.buyer_city,
        state=order.buyer_state,
        postcode=order.buyer_postcode,
    )
    return BuyerOut(
        name=order.customer_name,
        tin=order.buyer_tin,
        id_type=order.buyer_id_type,
        id_number=order.buyer_id_number,
        address_line1=order.buyer_address_line1,
        address_line2=order.buyer_address_line2,
        city=order.buyer_city,
        state=order.buyer_state,
        postcode=order.buyer_postcode,
        msic_code=order.buyer_msic_code,
        einvoice_requested=order.einvoice_requested,
        captured_at=order.buyer_captured_at,
        complete=buyer_details_complete(buyer),
        missing=[m.value for m in missing_buyer_details(buyer)],
    )


def _override_out(row: PriceOverride) -> PriceOverrideOut:
    return PriceOverrideOut(
        id=row.id,
        order_line_id=row.order_line_id,
        order_id=row.order_id,
        before_sen=row.before_sen,
        after_sen=row.after_sen,
        reason=row.reason,
        admin_user_id=row.admin_user_id,
        at=row.at,
    )


def overrides_between(
    session: Session, *, start: datetime, end: datetime
) -> list[PriceOverrideOut]:
    """Every price moved by hand in a window, newest first. §6.5.

    Half-open, so one row lands in exactly one week. §6.5 puts the entire
    control on this being read: *"without it the log is never read and the
    control does not exist."*
    """
    rows = session.scalars(
        select(PriceOverride)
        .where(PriceOverride.at >= start, PriceOverride.at < end)
        .order_by(PriceOverride.at.desc())
    )
    return [_override_out(row) for row in rows]


def prompts_between(
    session: Session, *, start: datetime, end: datetime
) -> list[DepositPromptOut]:
    """Every answer to the category prompt in a window, oldest first. §6.2.

    Returned raw rather than summarised. The arithmetic lives on the device in
    ``summariseDeposits`` and the dashboard will want to slice it differently --
    by salesperson, by fair -- so aggregating here would mean two summaries that
    have to agree and eventually will not.
    """
    rows = session.scalars(
        select(DepositPrompt)
        .where(DepositPrompt.at >= start, DepositPrompt.at < end)
        .order_by(DepositPrompt.at)
    )
    return [
        DepositPromptOut(
            id=row.id,
            quote_id=row.quote_id,
            category=row.category,
            choice=row.choice,
            category_subtotal_sen=row.category_subtotal_sen,
            at=row.at,
        )
        for row in rows
    ]

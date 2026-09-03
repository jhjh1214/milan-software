"""Accepting a quote from a device, and re-pricing it.

§9.2 and §9.4, which between them are the whole of the push side:

- **Idempotent on the client UUID.** A fair's connection drops mid-request, the
  device cannot tell whether the server got it, so it sends again. A retry must
  change nothing and report success.
- **The server re-prices every line** from the version the device recorded.
  Match: accept silently. Mismatch: **accept the order anyway**, store both
  numbers, and raise it for review. Never lose a sale over a rounding dispute;
  never silently accept the client's number either.

PURE of HTTP. The router calls this; the tests call it directly.
"""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..api.schemas import (
    LineResult,
    OrderIn,
    OrderResult,
    PaymentIn,
    PaymentResult,
    PushResult,
    QuoteIn,
    StatusChangeIn,
    StatusChangeResult,
)
from ..core.length import Length
from ..models.db import (
    IdempotencyRecord,
    Order,
    OrderEvent,
    OrderLine,
    Payment,
    PriceOverride,
    PricingDiscrepancy,
    Quote,
    QuoteLine,
    RateCardVersion,
    User,
)
from ..pricing.engine import (
    LineRequest,
    NoApplicableRate,
    ProductRuleViolation,
    price_line,
    total_quote,
)
from ..pricing.models import (
    CustomerTier,
    Fulfilment,
    Layer,
    PricingStage,
    RateCard,
)
from ..pricing.order_status import (
    OrderLineState,
    OrderStatus,
    UnknownOrderStatus,
    advance_order,
)
from ..pricing.price_override import override_line_price
from .order_numbers import issue_order_no
from .receipts import issue_receipt_no


class UnknownRateCardVersion(Exception):
    """The device priced against a version this server has never published.

    Refused rather than re-priced at whatever is current: quietly substituting
    today's card would reprice a quote the customer has already been shown.
    """


def push_quote(
    session: Session, payload: QuoteIn, *, taken_by: User | None = None
) -> PushResult:
    """Accepts one quote.

    ``taken_by`` comes from the session that pushed it, never from the request
    body: a handset must not be able to claim the quote was someone else's.
    """
    existing = session.get(Quote, payload.id)
    if existing is not None:
        # Already accepted. Report the stored figures rather than re-running,
        # so a retry is byte-identical to the first response.
        return PushResult(
            quote_id=existing.id,
            duplicate=True,
            server_total_sen=existing.server_total_sen,
            device_total_sen=existing.device_total_sen,
            discrepancies=[],
        )

    card_row = session.get(RateCardVersion, payload.rate_card_version)
    if card_row is None:
        raise UnknownRateCardVersion(
            f"no published rate card at version {payload.rate_card_version}"
        )
    card = RateCard.from_json(card_row.payload)

    quote = Quote(
        id=payload.id,
        rate_card_version=payload.rate_card_version,
        tier=payload.tier,
        language=payload.language,
        customer_name=payload.customer_name,
        customer_phone=payload.customer_phone,
        delivery_zone_id=payload.delivery_zone_id,
        device_total_sen=payload.device_total_sen,
        created_at=payload.created_at,
        updated_at=payload.updated_at,
        device_id=payload.device_id,
        taken_by_user_id=None if taken_by is None else taken_by.id,
    )
    session.add(quote)

    tier = CustomerTier.MVP if payload.tier == "mvp" else CustomerTier.STANDARD
    priced_lines = []
    results: list[LineResult] = []

    for line in payload.lines:
        row = QuoteLine(
            id=line.id,
            quote_id=quote.id,
            sort_order=line.sort_order,
            room=line.room,
            variant=line.variant,
            material_key=line.material_key,
            layer=line.layer,
            parent_line_id=line.parent_line_id,
            width_tmm=line.width_tmm,
            height_tmm=line.height_tmm,
            raw_width=line.raw_width,
            raw_height=line.raw_height,
            quantity=line.quantity,
            device_total_sen=line.device_total_sen,
        )

        detail: str | None = None
        server_total: int | None = None
        try:
            priced = price_line(
                request=LineRequest(
                    variant=line.variant,
                    material_key=line.material_key,
                    layer=Layer(line.layer),
                    fulfilment=Fulfilment.SUPPLY_INSTALL,
                    width=Length(line.width_tmm),
                    height=(
                        None if line.height_tmm is None else Length(line.height_tmm)
                    ),
                    quantity=line.quantity,
                ),
                card=card,
                # A pushed quote is an estimate. Final pricing happens at
                # measurement, in Phase 6.
                stage=PricingStage.ESTIMATE,
                tier=tier,
            )
            priced_lines.append(priced)
            server_total = priced.total.sen
        except (NoApplicableRate, ProductRuleViolation) as exc:
            # The line still lands. A quote the server cannot price is a data
            # problem to review, not a reason to reject a confirmed sale.
            detail = str(exc)

        row.server_total_sen = server_total
        session.add(row)

        agreed = (
            line.device_total_sen is not None
            and server_total is not None
            and line.device_total_sen == server_total
        )
        if not agreed:
            results.append(
                LineResult(
                    line_id=line.id,
                    server_total_sen=server_total,
                    device_total_sen=line.device_total_sen,
                    agreed=False,
                    detail=detail,
                )
            )
            if line.device_total_sen is not None and server_total is not None:
                session.add(
                    PricingDiscrepancy(
                        id=str(uuid.uuid4()),
                        quote_id=quote.id,
                        line_id=line.id,
                        rate_card_version=payload.rate_card_version,
                        device_total_sen=line.device_total_sen,
                        server_total_sen=server_total,
                        detail=detail,
                    )
                )

    totals = total_quote(
        lines=priced_lines,
        card=card,
        stage=PricingStage.ESTIMATE,
        delivery_zone_id=payload.delivery_zone_id,
    )
    quote.server_total_sen = totals.total.sen

    session.add(
        IdempotencyRecord(
            key=f"quote:{payload.id}",
            entity_type="quote",
            entity_id=payload.id,
        )
    )
    session.flush()

    return PushResult(
        quote_id=quote.id,
        duplicate=False,
        server_total_sen=quote.server_total_sen,
        device_total_sen=quote.device_total_sen,
        discrepancies=results,
    )


def push_payment(
    session: Session, payload: PaymentIn, *, taken_by: User | None = None
) -> PaymentResult:
    """Accepts a payment and issues its receipt number. §6.4, §9.2.

    **Idempotent on the device's own payment id.** A fair's connection drops
    mid-request constantly; a retry must not take the same RM300 twice, and it
    must hand back the *same* receipt number, because the customer may already
    be holding one with that number printed on it.

    The number is issued here and only here. CLAUDE.md: receipt numbers are a
    server-issued exception to client-generated ids, because they go on a legal
    document and two handsets offline at one fair would invent the same one.
    """
    existing = session.get(Payment, payload.id)
    if existing is not None:
        return PaymentResult(
            payment_id=existing.id,
            duplicate=True,
            # Never re-issued. A second number for one payment is a second
            # receipt for money that was taken once.
            receipt_no=existing.receipt_no or "",
        )

    receipt_no = issue_receipt_no(session, taken_at=payload.taken_at.date())

    session.add(
        Payment(
            id=payload.id,
            quote_id=payload.quote_id,
            category_lock_id=payload.category_lock_id,
            kind=payload.kind,
            amount_sen=payload.amount_sen,
            method=payload.method,
            external_ref=payload.external_ref,
            receipt_no=receipt_no,
            taken_by_user_id=None if taken_by is None else taken_by.id,
            taken_at=payload.taken_at,
            device_id=payload.device_id,
            status="settled",
        )
    )
    session.add(
        IdempotencyRecord(
            key=f"payment:{payload.id}",
            entity_type="payment",
            entity_id=payload.id,
        )
    )
    session.flush()

    return PaymentResult(payment_id=payload.id, duplicate=False, receipt_no=receipt_no)


def push_order(
    session: Session, payload: OrderIn, *, confirmed_by: User | None = None
) -> OrderResult:
    """Accepts a confirmed order and issues its number. §6.3, §9.2.

    **Idempotent on the device's own order id.** A deposit is what confirms an
    order, so an order arriving here is money already taken. A retry after a
    dropped connection must not produce a second order for one RM300, and must
    hand back the *same* number, because the customer may already be holding
    paperwork with it printed on.

    The number is issued here and only here. CLAUDE.md makes order numbers a
    server-issued exception to client-generated ids for the same reason as
    receipt numbers: ``{branch}-{yymm}-{seq}`` has no per-device component, so
    two part-timers offline at one fair would both mint ``MLK-2608-0007``.

    ## What is re-validated, and what happens when it fails

    The money has been taken. Refusing the whole push would lose the sale and
    leave the only record of it on one handset, so nothing here rejects an
    order outright. Instead the parts that do not survive validation are left
    out and named in the result:

    - a **status** the server would not allow from the one it holds is not
      applied; the order stays where the server had it and the refusal is
      reported. A device that has moved a job to ``in_production`` against the
      rules must not drag the server with it;
    - an **override** the server would not allow is not stored, and its line
      keeps the total it arrived with. §6.5 puts the whole control on the audit
      row, so an override without a valid one is exactly the thing not to keep.

    Both are mirrored from the same modules the device used, against the same
    shared fixtures, so a disagreement means the two have genuinely drifted
    rather than that one of them is guessing.
    """
    existing = session.get(Order, payload.id)
    if existing is not None:
        return OrderResult(
            order_id=existing.id,
            duplicate=True,
            # Never re-issued. A second number for one order is a second piece
            # of paperwork for a sale that happened once.
            order_no=existing.order_no or "",
        )

    order_no = issue_order_no(session, confirmed_at=payload.confirmed_at.date())

    # A device may only push an order that starts where an order starts. The
    # pipeline is walked with `advance_status` afterwards, never jumped by
    # asserting a status in the payload.
    status_refused: str | None = None
    status = OrderStatus.CONFIRMED
    if payload.status != OrderStatus.CONFIRMED.value:
        try:
            wanted = OrderStatus.from_wire(payload.status)
        except UnknownOrderStatus:
            status_refused = "unknown_status"
        else:
            decision = advance_order(
                frm=OrderStatus.CONFIRMED,
                to=wanted,
                lines=[
                    OrderLineState(
                        needs_measuring=True,
                        has_final_dimensions=line.is_site_measured,
                        material_deferred=line.material_deferred,
                        material_chosen=line.material_key is not None,
                    )
                    for line in payload.lines
                ],
                # The device sends no cancellation reason on the order itself;
                # it is on the event. A cancelled order arriving in one push is
                # not a shape this system produces.
                reason=None,
            )
            if decision.is_allowed and decision.to is not None:
                status = decision.to
            else:
                status_refused = (
                    decision.refused_because.value
                    if decision.refused_because is not None
                    else "not_a_transition"
                )

    session.add(
        Order(
            id=payload.id,
            quote_id=payload.quote_id,
            order_no=order_no,
            channel=payload.channel,
            pinned_rate_card_version=payload.pinned_rate_card_version,
            customer_name=payload.customer_name,
            customer_phone=payload.customer_phone,
            delivery_zone_id=payload.delivery_zone_id,
            delivery_charge_sen=payload.delivery_charge_sen,
            status=status.value,
            estimate_total_sen=payload.estimate_total_sen,
            deposit_paid_sen=payload.deposit_paid_sen,
            has_unmeasured_lines=payload.has_unmeasured_lines,
            confirmed_by_user_id=None if confirmed_by is None else confirmed_by.id,
            confirmed_at=payload.confirmed_at,
            device_id=payload.device_id,
        )
    )

    for line in payload.lines:
        session.add(
            OrderLine(
                id=line.id,
                order_id=payload.id,
                quote_line_id=line.quote_line_id,
                sort_order=line.sort_order,
                room=line.room,
                variant=line.variant,
                material_key=line.material_key,
                layer=line.layer,
                parent_line_id=line.parent_line_id,
                est_width_tmm=line.est_width_tmm,
                est_height_tmm=line.est_height_tmm,
                final_width_tmm=line.final_width_tmm,
                final_height_tmm=line.final_height_tmm,
                is_site_measured=line.is_site_measured,
                quantity=line.quantity,
                category_lock_id=line.category_lock_id,
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
        )

    for event in payload.events:
        session.add(
            OrderEvent(
                id=event.id,
                order_id=payload.id,
                event=event.event,
                note=event.note,
                by_user_id=None if confirmed_by is None else confirmed_by.id,
                at=event.at,
            )
        )

    known_lines = {line.id for line in payload.lines}
    overrides_refused: dict[str, str] = {}
    for override in payload.overrides:
        if override.order_line_id not in known_lines:
            # An audit row pointing at no line is a row the weekly review
            # cannot explain, which is the one thing §6.5 needs it to do.
            overrides_refused[override.id] = "unknown_line"
            continue

        decision = override_line_price(
            before_sen=override.before_sen,
            after_sen=override.after_sen,
            reason=override.reason,
            admin_user_id=override.admin_user_id,
            # The device already checked the role; the server checks the shape.
            # Whether the named user is really an admin is §13 C8, which is
            # unanswered -- the device has no role list to lie about yet.
            is_admin=True,
            order_is_terminal=status.is_terminal,
        )
        if not decision.is_applied or decision.record is None:
            overrides_refused[override.id] = (
                decision.refused_because.value
                if decision.refused_because is not None
                else "refused"
            )
            continue

        session.add(
            PriceOverride(
                id=override.id,
                order_line_id=override.order_line_id,
                order_id=payload.id,
                before_sen=decision.record.before_sen,
                after_sen=decision.record.after_sen,
                reason=decision.record.reason,
                admin_user_id=decision.record.admin_user_id,
                device_id=override.device_id,
                at=override.at,
            )
        )

    session.add(
        IdempotencyRecord(
            key=f"order:{payload.id}",
            entity_type="order",
            entity_id=payload.id,
        )
    )
    session.flush()

    return OrderResult(
        order_id=payload.id,
        duplicate=False,
        order_no=order_no,
        status_refused_because=status_refused,
        overrides_refused=overrides_refused,
    )


def advance_order_status(
    session: Session, payload: StatusChangeIn, *, by: User | None = None
) -> StatusChangeResult:
    """Moves an order along the pipeline on the server. §6.3, §9.2.

    The device has already made this move locally and is telling the server
    about it. The server re-validates rather than trusting it, against the same
    module and the same shared fixtures the device used, so a disagreement means
    the two have genuinely drifted rather than that one is guessing.

    **Idempotent on the event id**, not on the order. An order walks the
    pipeline many times, so the thing that must not happen twice is one
    particular move -- and a retry after a dropped connection has to be
    harmless without blocking the next legitimate step.

    A refusal is reported, not raised. The device is offline-first and may be
    hours ahead; if the server will not make the move the device needs to know
    which one was rejected and why, not receive a 400 with the whole batch lost.
    """
    existing = session.get(OrderEvent, payload.event_id)
    if existing is not None:
        order = session.get(Order, payload.order_id)
        return StatusChangeResult(
            order_id=payload.order_id,
            duplicate=True,
            status=order.status if order is not None else payload.to,
        )

    order = session.get(Order, payload.order_id)
    if order is None:
        # The order push has not landed yet. The outbox is FIFO so this should
        # not happen, but saying so plainly beats writing an event that points
        # at nothing.
        return StatusChangeResult(
            order_id=payload.order_id,
            duplicate=False,
            status="",
            refused_because="unknown_order",
        )

    try:
        to = OrderStatus.from_wire(payload.to)
    except UnknownOrderStatus:
        return StatusChangeResult(
            order_id=order.id,
            duplicate=False,
            status=order.status,
            refused_because="unknown_status",
        )

    lines = session.scalars(
        select(OrderLine).where(OrderLine.order_id == order.id)
    ).all()

    decision = advance_order(
        frm=OrderStatus.from_wire(order.status),
        to=to,
        reason=payload.reason,
        lines=[
            OrderLineState(
                # The same rule the device applies: everything needs a tape
                # taking to it. §8.5's promise is kept by measuring.
                needs_measuring=True,
                has_final_dimensions=line.is_site_measured,
                material_deferred=line.material_deferred,
                material_chosen=line.material_key is not None,
            )
            for line in lines
        ],
    )

    if not decision.is_allowed or decision.to is None:
        return StatusChangeResult(
            order_id=order.id,
            duplicate=False,
            status=order.status,
            refused_because=(
                decision.refused_because.value
                if decision.refused_because is not None
                else "refused"
            ),
        )

    order.status = decision.to.value
    session.add(
        OrderEvent(
            id=payload.event_id,
            order_id=order.id,
            event=decision.to.value,
            # Stored as given. A cancellation reason is the row §13 B3 will be
            # settled from.
            note=(payload.reason or "").strip() or None,
            by_user_id=None if by is None else by.id,
            at=payload.at,
        )
    )
    session.flush()

    return StatusChangeResult(order_id=order.id, duplicate=False, status=order.status)


def active_card(session: Session, list_id: str) -> RateCardVersion | None:
    return session.scalars(
        select(RateCardVersion).where(
            RateCardVersion.list_id == list_id,
            RateCardVersion.is_active.is_(True),
        )
    ).first()


def publish_card(
    session: Session,
    *,
    list_id: str,
    payload: dict,
    published_by: str | None = None,
) -> RateCardVersion:
    """Publishes a card as the active one for its list.

    The previous version is deactivated but **kept**: a quote priced at it must
    remain explainable (CLAUDE.md — rows are never updated in place and never
    deleted).
    """
    current = active_card(session, list_id)
    if current is not None:
        current.is_active = False
        session.flush()

    row = RateCardVersion(
        version=payload["version"],
        list_id=list_id,
        payload=payload,
        is_active=True,
        published_by=published_by,
    )
    session.add(row)
    session.flush()
    return row

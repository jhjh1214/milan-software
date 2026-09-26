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

import copy
import uuid
from datetime import UTC, datetime
from fractions import Fraction

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..api.schemas import (
    BuyerDetailsIn,
    BuyerDetailsResult,
    CategoryLockIn,
    DepositPromptIn,
    DepositPromptResult,
    LineResult,
    LockPushResult,
    MeasurementIn,
    MeasurementResult,
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
from ..core.money import Money
from ..models.db import (
    CategoryLock,
    DepositPrompt,
    IdempotencyRecord,
    Order,
    OrderEvent,
    OrderLine,
    Payment,
    PriceOverride,
    PricingDiscrepancy,
    Quote,
    QuoteLine,
    RateCardEdit,
    RateCardVersion,
    User,
)
from ..pricing.einvoice_threshold import (
    BuyerDetails,
    buyer_details_complete,
    missing_buyer_details,
)
from ..pricing.engine import (
    LineRequest,
    NoApplicableRate,
    ProductRuleViolation,
    price_line,
    total_quote,
)
from ..pricing.final_pricing import MeasuredLine, reprice_order
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
from ..pricing.rate_edit import RateEditRefusal, decide_rate_edit
from .inventory import propose_allocation_for_line
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
            direct_area_sqft=line.direct_area_sqft,
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
                    width=None if line.width_tmm is None else Length(line.width_tmm),
                    height=(
                        None if line.height_tmm is None else Length(line.height_tmm)
                    ),
                    direct_area_sqft=(
                        None
                        if line.direct_area_sqft is None
                        else Fraction(line.direct_area_sqft)
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
                direct_area_sqft=line.direct_area_sqft,
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
                measurement_source=line.measurement_source,
                source_project_id=line.source_project_id,
                source_unit_type_id=line.source_unit_type_id,
                source_version=line.source_version,
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


def _merged(current: str | None, incoming: str | None) -> str | None:
    """Applies one buyer field: absent leaves it, empty clears it.

    ``None`` means the payload did not carry this field, so whatever is already
    stored stands. Two people can capture for one order -- the measurer takes
    the TIN at the house, the office adds the address later -- and a push that
    blanked what it did not carry would lose whichever landed first.

    A string that trims to nothing is an explicit clear. That is how a wrong
    IC number gets removed, and it is why the trim happens here rather than
    being trusted to the caller: a field holding a space must not satisfy a
    legal requirement.
    """
    if incoming is None:
        return current
    trimmed = incoming.strip()
    return trimmed or None


def set_site_address_note(
    session: Session, order_id: str, note: str | None
) -> Order | None:
    """Staff typing in where a site visit actually is, from whatever they
    already have -- a fair form, a WhatsApp message. Free text, not a real
    address record: no postcode, no geocoding, just enough to open a free
    Google Maps search link (§13 C10's write-up) before the visit.

    Plain replace, unlike ``push_buyer_details``: only the dashboard ever
    writes this field, so there is no offline handset racing another one and
    nothing to merge or stale-check.

    Returns ``None`` for an unknown order -- the route turns that into a 404,
    the ordinary REST answer, rather than the buyer-details endpoint's
    refused-as-200 (that shape exists because an outbox retries a push; a
    dashboard PATCH to a stale order id is just a bug worth surfacing loudly).
    """
    order = session.get(Order, order_id)
    if order is None:
        return None
    order.site_address_note = (note or "").strip() or None
    session.flush()
    return order


def push_buyer_details(session: Session, payload: BuyerDetailsIn) -> BuyerDetailsResult:
    """Records what was captured about the buyer. SPEC.md §10.3, §11 Phase 7.

    Its own endpoint rather than a field on the order push, because an order is
    pushed **once at confirmation** and these are captured after measurement --
    by which point that payload was sent hours or days ago.

    On the server as well as the device because the **office** runs the SQL
    Account export, and details that never leave a handset are the same as no
    details as far as the accounts system is concerned. That is exactly the
    failure the rate locks had before migration 0005: correct machinery, stored
    where nothing else could read it.

    **Idempotent, and safe to retry**, because it merges rather than replaces:
    sending the same payload twice reaches the same row. A push carrying an
    older ``captured_at`` than the one already stored is refused as ``stale``
    rather than applied -- several handsets work one fair, any of them can
    capture for an order, and an out-of-order delivery must not undo the newer
    answer. It refuses the whole push rather than merging field by field: a
    half-applied older record is a buyer nobody can account for.

    Nothing here re-decides whether the details were *needed*. That is the
    threshold rule, checked by the state machine when the order tries to move.
    What comes back is whether the record is now complete, from the same rule
    the device shows, so the two cannot disagree about who still has to be
    telephoned.
    """
    order = session.get(Order, payload.order_id)
    if order is None:
        # The order push has not landed. The outbox is FIFO so this should not
        # happen, but saying so plainly beats writing details onto nothing.
        return BuyerDetailsResult(
            order_id=payload.order_id,
            complete=False,
            missing=[],
            refused_because="unknown_order",
        )

    stored_at = order.buyer_captured_at
    if stored_at is not None and payload.captured_at < _as_utc(stored_at):
        return BuyerDetailsResult(
            order_id=order.id,
            complete=buyer_details_complete(_buyer_of(order)),
            missing=[m.value for m in missing_buyer_details(_buyer_of(order))],
            refused_because="stale",
        )

    order.customer_name = _merged(order.customer_name, payload.name)
    order.buyer_tin = _merged(order.buyer_tin, payload.tin)
    order.buyer_id_type = _merged(order.buyer_id_type, payload.id_type)
    order.buyer_id_number = _merged(order.buyer_id_number, payload.id_number)
    order.buyer_address_line1 = _merged(
        order.buyer_address_line1, payload.address_line1
    )
    order.buyer_address_line2 = _merged(
        order.buyer_address_line2, payload.address_line2
    )
    order.buyer_city = _merged(order.buyer_city, payload.city)
    order.buyer_state = _merged(order.buyer_state, payload.state)
    order.buyer_postcode = _merged(order.buyer_postcode, payload.postcode)
    order.buyer_msic_code = _merged(order.buyer_msic_code, payload.msic_code)
    if payload.einvoice_requested is not None:
        order.einvoice_requested = payload.einvoice_requested
    order.buyer_captured_at = payload.captured_at

    session.flush()

    buyer = _buyer_of(order)
    return BuyerDetailsResult(
        order_id=order.id,
        complete=buyer_details_complete(buyer),
        missing=[m.value for m in missing_buyer_details(buyer)],
    )


def _buyer_of(order: Order) -> BuyerDetails:
    """The stored row as the rule wants it.

    A function rather than a stored ``is_complete`` column: what counts as
    complete is a rule, and a boolean beside it would be a second answer that
    drifts the first time somebody edits a field without recomputing it.
    """
    return BuyerDetails(
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


def _as_utc(value: datetime) -> datetime:
    """SQLite drops the timezone off a ``timestamptz``; Postgres does not.

    Comparing an aware payload against a naive stored value raises, and it
    would raise only under SQLite -- so it would pass every local test and fail
    the first time somebody pushed a correction in production.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def push_measurement(
    session: Session, payload: MeasurementIn, *, by: User | None = None
) -> MeasurementResult:
    """Records a site measurement pushed up after the device took it.

    SPEC.md §11 Phase 6. Its own endpoint, for the same reason buyer details
    get one: an order is pushed **once at confirmation**, before the site
    visit happens -- ``push_order``'s idempotency check treats a retry with
    an existing order id as a pure duplicate and never touches its lines
    again, so without this a tape reading taken in the field never reaches
    the server. That is what left ``advance_order_status``'s ``measured``
    guard permanently starved: it reads ``OrderLine.is_site_measured`` fresh
    on every call, but nothing ever wrote it after the initial
    (always-``False``) insert.

    Staled on the LINE's own ``measured_at``, not the order's -- each line is
    measured independently, sometimes on different visits, so an order-wide
    timestamp would let one late line refuse a push about a different one. A
    later ``measured_at`` always wins, which is what §6.3 means by a
    remeasure being new dimensions on the same order rather than a rewind.

    Reprices the WHOLE order on every measurement, mirroring
    ``MeasurementRepository._repriceAndStore`` on the device: the stored
    totals must not drift out of step with the lines under them.

    ``measured_by_user_id`` comes from the authenticated session, never the
    payload -- the same rule ``push_quote``'s ``taken_by`` follows, so a
    handset cannot claim a measurement was someone else's.

    A device/server total disagreement on the line just measured is logged to
    ``pricing_discrepancies`` rather than argued about -- hard rule 4, the
    same as every other pricing push.
    """
    order = session.get(Order, payload.order_id)
    if order is None:
        # The order push has not landed. The outbox is FIFO so this should
        # not happen, but saying so plainly beats writing a measurement onto
        # nothing.
        return MeasurementResult(
            order_id=payload.order_id,
            line_id=payload.line_id,
            is_site_measured=False,
            refused_because="unknown_order",
        )

    line = session.get(OrderLine, payload.line_id)
    if line is None or line.order_id != order.id:
        return MeasurementResult(
            order_id=order.id,
            line_id=payload.line_id,
            is_site_measured=False,
            final_total_sen=order.final_total_sen,
            has_unmeasured_lines=order.has_unmeasured_lines,
            refused_because="unknown_line",
        )

    if line.measured_at is not None and payload.measured_at < _as_utc(line.measured_at):
        return MeasurementResult(
            order_id=order.id,
            line_id=line.id,
            is_site_measured=line.is_site_measured,
            final_total_sen=order.final_total_sen,
            has_unmeasured_lines=order.has_unmeasured_lines,
            refused_because="stale",
        )

    line.final_width_tmm = payload.final_width_tmm
    line.final_height_tmm = payload.final_height_tmm
    line.is_site_measured = True
    line.measured_by_user_id = None if by is None else by.id
    line.measured_at = payload.measured_at
    if payload.material_key is not None:
        line.material_key = payload.material_key

    all_lines = session.scalars(
        select(OrderLine).where(OrderLine.order_id == order.id)
    ).all()

    cards: dict[int, RateCard] = {}
    for version in {row.applied_rate_card_version for row in all_lines}:
        card_row = session.get(RateCardVersion, version)
        if card_row is not None:
            cards[version] = RateCard.from_json(card_row.payload)

    pricing = reprice_order(
        lines=[
            MeasuredLine(
                id=row.id,
                variant=row.variant,
                estimate_total=Money(row.line_total_sen),
                applied_rate_card_version=row.applied_rate_card_version,
                material_key=row.material_key,
                layer=Layer(row.layer),
                quantity=row.quantity,
                final_width=(
                    None if row.final_width_tmm is None else Length(row.final_width_tmm)
                ),
                final_height=(
                    None
                    if row.final_height_tmm is None
                    else Length(row.final_height_tmm)
                ),
                material_deferred=row.material_deferred,
            )
            for row in all_lines
        ],
        cards=cards,
    )

    order.final_total_sen = pricing.final_total.sen if pricing.is_complete else None
    order.has_unmeasured_lines = not pricing.is_complete

    this_line = next((pl for pl in pricing.lines if pl.id == line.id), None)
    server_total_sen = (
        this_line.final_total.sen
        if this_line is not None and this_line.final_total is not None
        else None
    )
    if (
        payload.device_final_total_sen is not None
        and server_total_sen is not None
        and payload.device_final_total_sen != server_total_sen
    ):
        session.add(
            PricingDiscrepancy(
                id=str(uuid.uuid4()),
                quote_id=order.quote_id,
                line_id=line.id,
                rate_card_version=line.applied_rate_card_version,
                device_total_sen=payload.device_final_total_sen,
                server_total_sen=server_total_sen,
                detail="final pricing",
            )
        )

    # SPEC.md Phase 9's one auto-allocation trigger: right after this line's
    # final pricing is known. `this_line.billed_qty` is the exact quantity
    # `reprice_order` just computed, never `line.billed_qty` -- that column
    # is the fair's rounded-up estimate and never updated. Proposes only
    # where the conversion is exact (§13 F3); does nothing for the ordinary
    # case of a non-inventory-tracked or fabric-billed line.
    propose_allocation_for_line(
        session,
        order_line=line,
        order_id=order.id,
        final_billed_qty=None if this_line is None else this_line.billed_qty,
    )

    session.flush()

    return MeasurementResult(
        order_id=order.id,
        line_id=line.id,
        is_site_measured=line.is_site_measured,
        final_total_sen=order.final_total_sen,
        has_unmeasured_lines=order.has_unmeasured_lines,
    )


def push_category_lock(
    session: Session, payload: CategoryLockIn, *, opened_by: User | None = None
) -> LockPushResult:
    """Accepts a hold opened on a handset. §6.1, §9.2.

    **Idempotent on the device's own lock id.** The RM300 was taken before this
    row existed, so a retry after a dropped connection must not produce a
    second hold for one deposit.

    Nothing here re-decides whether the hold was allowed. ``open_category_lock``
    already refused outside a fair and below the minimum, on the device, at the
    moment the money changed hands -- and refusing it now would leave a customer
    who has paid RM300 holding nothing.

    A **conflict** is stored rather than dropped. If the server already has a
    different active lock for this customer and category, two handsets have each
    taken a deposit for the same thing, which is a real afternoon at a busy
    fair. Both are real money. The newer arrival is recorded as ``superseded``
    so the older hold keeps pricing, and the result names the clash so somebody
    can refund one -- silently discarding either would lose a payment nobody
    could then find.
    """
    existing = session.get(CategoryLock, payload.id)
    if existing is not None:
        return LockPushResult(lock_id=existing.id, duplicate=True)

    conflict = None
    if payload.status == "active":
        conflict = session.scalars(
            select(CategoryLock).where(
                CategoryLock.customer_key == payload.customer_key,
                CategoryLock.category == payload.category,
                CategoryLock.status == "active",
            )
        ).first()

    session.add(
        CategoryLock(
            id=payload.id,
            customer_key=payload.customer_key,
            category=payload.category,
            deposit_payment_id=payload.deposit_payment_id,
            held_rate_card_version=payload.held_rate_card_version,
            held_discount_pct=payload.held_discount_pct,
            held_until=payload.held_until,
            # The first hold keeps pricing. Whichever RM300 arrived second is
            # the one to refund, and that is a decision for a person.
            status="superseded" if conflict is not None else payload.status,
            opened_by_user_id=None if opened_by is None else opened_by.id,
            opened_at=payload.opened_at,
            device_id=payload.device_id,
        )
    )
    session.add(
        IdempotencyRecord(
            key=f"lock:{payload.id}",
            entity_type="category_lock",
            entity_id=payload.id,
        )
    )
    session.flush()

    return LockPushResult(
        lock_id=payload.id,
        duplicate=False,
        conflicts_with=None if conflict is None else conflict.id,
    )


def push_deposit_prompt(
    session: Session, payload: DepositPromptIn, *, by: User | None = None
) -> DepositPromptResult:
    """Accepts one answer to the category prompt. §6.2.

    Append-only and idempotent on the device's id. The declined-deposit report
    is the reason this exists: it only tells the boss what fairs are leaving on
    the table if a decline reaches the server as reliably as a sale does.
    """
    existing = session.get(DepositPrompt, payload.id)
    if existing is not None:
        return DepositPromptResult(prompt_id=existing.id, duplicate=True)

    session.add(
        DepositPrompt(
            id=payload.id,
            quote_id=payload.quote_id,
            category=payload.category,
            choice=payload.choice,
            category_subtotal_sen=payload.category_subtotal_sen,
            by_user_id=None if by is None else by.id,
            at=payload.at,
            device_id=payload.device_id,
        )
    )
    session.flush()
    return DepositPromptResult(prompt_id=payload.id, duplicate=False)


def locks_for_customer(session: Session, customer_key: str) -> list[CategoryLock]:
    """Every hold this customer still has, newest first.

    The lookup a handset makes when it learns a phone number. Without it a hold
    is one handset's secret: six phones work a fair, the customer deposits on
    phone 3, and walks into the showroom in March where phone 1 is used.

    Expiry is not filtered here. ``resolve_rate_basis`` decides whether a hold
    is still good against the date it is pricing on, and a handset that has not
    synced today needs the row to make that judgement itself.
    """
    return list(
        session.scalars(
            select(CategoryLock)
            .where(
                CategoryLock.customer_key == customer_key,
                CategoryLock.status == "active",
            )
            .order_by(CategoryLock.opened_at.desc())
        )
    )


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


def next_card_version(session: Session) -> int:
    """The version a server-built card publishes at.

    Global, not just "one more than this list's active version":
    `rate_cards.version` is the sole primary key across both lineages, so a
    number already used by the other list would collide.
    """
    existing_versions = session.scalars(select(RateCardVersion.version)).all()
    return (max(existing_versions) if existing_versions else 0) + 1


class NoSuchProduct(Exception):
    pass


class RateEditRefused(Exception):
    def __init__(self, reason: RateEditRefusal) -> None:
        self.reason = reason
        super().__init__(reason.value)


def edit_product_price(
    session: Session,
    *,
    list_id: str,
    rule_id: str,
    rate_sen: int,
    mvp_rate_sen: int | None,
    reason: str,
    by_user_id: str,
    at: datetime | None = None,
) -> RateCardEdit:
    """Changes one product's price directly, live immediately -- no
    whole-card upload, no preview ceremony. A staff or admin member reacting
    to a competitor at a fair should not have to reach an admin who can
    reach a computer.

    Still never edits a row in place: publishes a new `RateCardVersion` with
    just this one rule changed, so a quote already priced at the old rate,
    or a rate lock pinned to the old version, both stay explainable exactly
    as they would after a whole-card publish.
    """
    live = active_card(session, list_id)
    rule = None
    if live is not None:
        rule = next(
            (r for r in live.payload.get("rules", []) if r.get("id") == rule_id),
            None,
        )

    decision = decide_rate_edit(
        rule_id=rule_id,
        list_id=list_id,
        before_rate_sen=None if rule is None else rule["rate_sen"],
        after_rate_sen=rate_sen,
        before_mvp_rate_sen=None if rule is None else rule.get("mvp_rate_sen"),
        after_mvp_rate_sen=mvp_rate_sen,
        reason=reason,
        by_user_id=by_user_id,
    )
    if decision.refused_because is RateEditRefusal.NO_SUCH_PRODUCT:
        raise NoSuchProduct(rule_id)
    if not decision.is_applied or decision.record is None:
        assert decision.refused_because is not None
        raise RateEditRefused(decision.refused_because)
    assert live is not None and rule is not None

    payload = copy.deepcopy(live.payload)
    new_rule = next(r for r in payload["rules"] if r["id"] == rule_id)
    new_rule["rate_sen"] = rate_sen
    new_rule["mvp_rate_sen"] = mvp_rate_sen
    # A22: supplying a real rate on a placeholder clears the flag in the
    # same edit -- a flag and a number that could drift apart is exactly
    # the "accepted but still refused" bug that rule exists to prevent.
    if new_rule.get("provisional") and rate_sen > 0:
        new_rule["provisional"] = False

    next_version = next_card_version(session)
    payload["version"] = next_version

    publish_card(session, list_id=list_id, payload=payload, published_by=by_user_id)

    edit = RateCardEdit(
        id=str(uuid.uuid4()),
        rule_id=rule_id,
        list_id=list_id,
        before_rate_sen=decision.record.before_rate_sen,
        after_rate_sen=decision.record.after_rate_sen,
        before_mvp_rate_sen=decision.record.before_mvp_rate_sen,
        after_mvp_rate_sen=decision.record.after_mvp_rate_sen,
        resulting_version=next_version,
        reason=decision.record.reason,
        by_user_id=by_user_id,
        at=at or datetime.now(UTC),
    )
    session.add(edit)
    session.flush()
    return edit

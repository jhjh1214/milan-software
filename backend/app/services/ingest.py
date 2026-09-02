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

from ..api.schemas import LineResult, PushResult, QuoteIn
from ..core.length import Length
from ..models.db import (
    IdempotencyRecord,
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

"""The API. Thin: it validates, delegates and maps errors to status codes.

Everything that decides a number lives in `app.pricing` and `app.services`, so
the tests that matter run without HTTP.

§9 shapes this. Sync is **asymmetric** — two one-way pipelines beat one general
engine — so there are exactly two routes that matter:

- ``GET  /api/bundle``  reference data down. Admin-only writes, so no merge
  conflicts by construction.
- ``POST /api/quotes``  transactions up. Idempotent on the client UUID.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query, status
from sqlalchemy.orm import Session

from .api.schemas import BundleOut, PushResult, QuoteIn
from .db import session_scope
from .services.ingest import (
    UnknownRateCardVersion,
    active_card,
    push_quote,
)

app = FastAPI(
    title="Milan Software",
    version="0.3.0",
    description=(
        "Sync and pricing for the Milan quotation app. This service does not "
        "issue invoices: SQL Account is the sole issuer of record (SPEC.md §10)."
    ),
)


def get_session() -> Iterator[Session]:
    with session_scope() as session:
        yield session


#: The `Annotated` form rather than a `Depends` default: a call in an
#: argument default is evaluated once at import, and FastAPI only gets away with
#: it by special-casing the value. This spelling says the same thing without the
#: sharp edge, and is what FastAPI documents now.
SessionDep = Annotated[Session, Depends(get_session)]


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/bundle", response_model=BundleOut)
def bundle(
    session: SessionDep,
    list_id: Annotated[str, Query(pattern="^(fair|standard)$")] = "fair",
    since_version: Annotated[int | None, Query()] = None,
) -> BundleOut:
    """The reference-data pull. §9.1.

    Replaced **wholesale** on the device, never diffed. When the device is
    already current the payload is omitted, so a fair's thin connection is not
    spent re-downloading a card it already has.
    """
    card = active_card(session, list_id)
    if card is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"no active rate card for list '{list_id}'",
        )

    if since_version is not None and since_version == card.version:
        return BundleOut(
            rate_card_version=card.version,
            list_id=card.list_id,
            payload=None,
            up_to_date=True,
        )

    return BundleOut(
        rate_card_version=card.version,
        list_id=card.list_id,
        payload=card.payload,
        up_to_date=False,
    )


@app.post("/api/quotes", response_model=PushResult)
def push(payload: QuoteIn, session: SessionDep) -> PushResult:
    """Accepts a quote from a device. §9.2 and §9.4.

    **Idempotent on the client's own quote id.** A retry returns 200 with
    ``duplicate: true`` rather than an error: the device cannot know whether the
    first attempt landed before the signal dropped, and treating a retry as a
    failure would have it retry forever.

    A pricing disagreement does **not** fail the request. The order is accepted,
    both numbers are kept and the discrepancy is raised for review — never lose
    a sale over a rounding dispute.
    """
    try:
        return push_quote(session, payload)
    except UnknownRateCardVersion as exc:
        # Refused rather than repriced at whatever is current: substituting
        # today's card would reprice a quote the customer has already seen.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail=str(exc)
        ) from exc

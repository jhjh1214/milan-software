"""The API. Thin: it validates, delegates and maps errors to status codes.

Everything that decides a number lives in `app.pricing` and `app.services`, so
the tests that matter run without HTTP.

§9 shapes this. Sync is **asymmetric** — two one-way pipelines beat one general
engine — so there are exactly two routes that carry data:

- ``GET  /api/bundle``  reference data down. Admin-only writes, so no merge
  conflicts by construction.
- ``POST /api/quotes``  transactions up. Idempotent on the client UUID.

Everything is authenticated except ``/api/health`` and the sign-in itself.
Sessions never expire (SPEC.md §12) — see ``app.services.auth`` for why, and for
what replaces expiry.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response, status
from sqlalchemy.orm import Session

from .api.schemas import (
    BundleOut,
    LoginIn,
    PublishIn,
    PublishOut,
    PushResult,
    QuoteIn,
    SessionOut,
    UserOut,
)
from .db import session_scope
from .models.db import DeviceSession, User
from .services.auth import (
    AuthenticationFailed,
    TooManyAttempts,
    authenticate,
    issue_session,
    resolve_token,
    revoke_session,
)
from .services.ingest import (
    UnknownRateCardVersion,
    active_card,
    publish_card,
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


#: The ``Annotated`` form rather than a ``Depends`` default: a call in an
#: argument default is evaluated once at import, and FastAPI only gets away with
#: it by special-casing the value. This spelling says the same thing without the
#: sharp edge, and is what FastAPI documents now.
SessionDep = Annotated[Session, Depends(get_session)]

#: Spelled out rather than taken from ``status``: Starlette renamed the constant
#: and deprecated the old name, and this pins neither spelling.
HTTP_422_UNPROCESSABLE = 422


def current(
    session: SessionDep,
    authorization: Annotated[str | None, Header()] = None,
) -> tuple[User, DeviceSession]:
    """The signed-in user, or 401.

    ``WWW-Authenticate`` is set so a client can tell "you are not signed in"
    from "you are signed in and not allowed to do this".
    """
    scheme, _, token = (authorization or "").partition(" ")
    resolved = resolve_token(session, token) if scheme.lower() == "bearer" else None
    if resolved is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="sign in required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return resolved


CurrentDep = Annotated[tuple[User, DeviceSession], Depends(current)]


def require_admin(who: CurrentDep) -> User:
    """Admin only. §3: staff see rates and cannot edit them; part-timers never
    see a rate at all."""
    user, _ = who
    if user.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="admin only",
        )
    return user


AdminDep = Annotated[User, Depends(require_admin)]


@app.get("/api/health")
def health() -> dict[str, str]:
    """Unauthenticated on purpose: it is what the container health check and the
    reverse proxy call, and it says nothing about the data."""
    return {"status": "ok"}


@app.post("/api/auth/login", response_model=SessionOut)
def login(payload: LoginIn, session: SessionDep) -> SessionOut:
    """Signs a handset in. The only unauthenticated route that touches data.

    A wrong PIN and an unknown phone answer identically — a different response
    would tell an attacker which numbers belong to staff.
    """
    try:
        user = authenticate(
            session,
            phone=payload.phone,
            pin=payload.pin,
            device_id=payload.device_id,
        )
    except TooManyAttempts as exc:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=str(exc),
            headers={"Retry-After": str(exc.retry_after_seconds)},
        ) from exc
    except AuthenticationFailed as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="phone or PIN is wrong",
        ) from exc

    token, _ = issue_session(
        session,
        user=user,
        device_id=payload.device_id,
        device_label=payload.device_label,
    )
    return SessionOut(
        token=token,
        user=UserOut(
            id=user.id, name=user.name, role=user.role, language=user.language
        ),
    )


@app.get("/api/auth/me", response_model=UserOut)
def me(who: CurrentDep) -> UserOut:
    """Who this token belongs to.

    The app calls it on reconnect to notice a revoked session, and to pick up a
    role or language changed in the office.
    """
    user, _ = who
    return UserOut(id=user.id, name=user.name, role=user.role, language=user.language)


@app.post("/api/auth/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(session: SessionDep, who: CurrentDep) -> Response:
    """Ends this handset's session. The row stays — it is who was signed in."""
    _, device_session = who
    revoke_session(
        session,
        device_session=device_session,
        reason="signed out on the device",
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/api/bundle", response_model=BundleOut)
def bundle(
    session: SessionDep,
    who: CurrentDep,
    list_id: Annotated[str, Query(pattern="^(fair|standard)$")] = "fair",
    since_version: Annotated[int | None, Query()] = None,
) -> BundleOut:
    """The reference-data pull. §9.1.

    Replaced **wholesale** on the device, never diffed. When the device is
    already current the payload is omitted, so a fair's thin connection is not
    spent re-downloading a card it already has.

    Open to every role, part-timers included: the device needs the card to price
    a line. Rule 8 — "part-timers never see a rate" — is a rule about what the
    screen shows, not about what the engine is handed.
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


@app.post("/api/rate-cards", response_model=PublishOut)
def publish(payload: PublishIn, session: SessionDep, admin: AdminDep) -> PublishOut:
    """Publishes a price list. Admin only.

    This is what makes prices server-owned (SPEC.md §11, Phase 3): one card,
    published once, pulled by every device. The alternative — each handset
    holding its own edited copy — is six handsets quoting six different prices
    at the same fair.

    The previous version is deactivated but kept, so a quote taken against it
    stays explainable.
    """
    if "version" not in payload.payload:
        raise HTTPException(
            status_code=HTTP_422_UNPROCESSABLE,
            detail="the card has no version",
        )

    version = payload.payload["version"]
    live = active_card(session, payload.list_id)
    if live is not None and version <= live.version:
        # Versions only go up. Re-using a number would leave two different
        # cards answering to one version, and a quote recording that version
        # could then mean either.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"version {version} is not newer than the active {live.version} "
                f"for '{payload.list_id}'"
            ),
        )

    row = publish_card(
        session,
        list_id=payload.list_id,
        payload=payload.payload,
        published_by=admin.id,
    )
    return PublishOut(
        version=row.version, list_id=row.list_id, published_by=row.published_by
    )


@app.post("/api/quotes", response_model=PushResult)
def push(payload: QuoteIn, session: SessionDep, who: CurrentDep) -> PushResult:
    """Accepts a quote from a device. §9.2 and §9.4.

    **Idempotent on the client's own quote id.** A retry returns 200 with
    ``duplicate: true`` rather than an error: the device cannot know whether the
    first attempt landed before the signal dropped, and treating a retry as a
    failure would have it retry forever.

    A pricing disagreement does **not** fail the request. The order is accepted,
    both numbers are kept and the discrepancy is raised for review — never lose
    a sale over a rounding dispute.
    """
    user, _ = who
    try:
        return push_quote(session, payload, taken_by=user)
    except UnknownRateCardVersion as exc:
        # Refused rather than repriced at whatever is current: substituting
        # today's card would reprice a quote the customer has already seen.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail=str(exc)
        ) from exc

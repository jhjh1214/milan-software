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
from datetime import UTC, datetime
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response, status
from sqlalchemy.orm import Session

from .api.schemas import (
    AddPersonIn,
    BalancesReport,
    BundleOut,
    BuyerDetailsIn,
    BuyerDetailsResult,
    CardDiffOut,
    CategoryLockIn,
    CategoryLockOut,
    DeactivateOut,
    DepositPromptIn,
    DepositPromptResult,
    DepositPromptsOut,
    FairReport,
    LockPushResult,
    LocksOut,
    LoginIn,
    MeasurementIn,
    MeasurementQueueOut,
    MeasurementResult,
    OrderDetailOut,
    OrderIn,
    OrderResult,
    OrdersOut,
    OverridesOut,
    PaymentIn,
    PaymentResult,
    PeopleOut,
    PersonOut,
    PreviewIn,
    PublishIn,
    PublishOut,
    PushResult,
    QuoteIn,
    RateChangeOut,
    SessionOut,
    SetPinIn,
    StatusChangeIn,
    StatusChangeResult,
    UserOut,
    VarianceReport,
)
from .core.security import WeakPin
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
from .services.card_diff import diff_cards
from .services.ingest import (
    UnknownRateCardVersion,
    active_card,
    advance_order_status,
    locks_for_customer,
    publish_card,
    push_buyer_details,
    push_category_lock,
    push_deposit_prompt,
    push_measurement,
    push_order,
    push_payment,
    push_quote,
)
from .services.measurement_queue import measurement_queue
from .services.people import (
    BadRole,
    NoSuchUser,
    PhoneTaken,
    add_person,
    deactivate,
    list_people,
    reactivate,
    set_pin,
)
from .services.reads import (
    MAX_PAGE,
    list_orders,
    order_detail,
    overrides_between,
    prompts_between,
)
from .services.reports import (
    fair_performance,
    outstanding_balances,
    variance_by_salesperson,
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


@app.post("/api/payments", response_model=PaymentResult)
def push_payment_route(
    payload: PaymentIn, session: SessionDep, who: CurrentDep
) -> PaymentResult:
    """Accepts a payment and issues its receipt number. §6.4.

    **Idempotent on the device's own payment id**, and a retry gets the *same*
    receipt number back — the customer may already be holding a printed one, and
    a second number for one payment is a second receipt for money taken once.

    The number is issued here and only here. A device that invented one would
    collide with every other device offline at the same fair, on a document a
    customer keeps.
    """
    user, _ = who
    return push_payment(session, payload, taken_by=user)


@app.post("/api/orders", response_model=OrderResult)
def push_order_route(
    payload: OrderIn, session: SessionDep, who: CurrentDep
) -> OrderResult:
    """Accepts a confirmed order and issues its number. §6.3.

    **Idempotent on the device's own order id**, and a retry gets the *same*
    order number back. A deposit is what confirms an order, so an order
    arriving here is money already taken — two orders for one RM300, or two
    numbers for one order, are both worse than a slow sync.

    Nothing here rejects an order outright. Refusing the push would lose the
    sale and leave the only record of it on one handset, so a status or an
    override the server would not have allowed is simply not applied, and the
    result names what was left out.
    """
    user, _ = who
    return push_order(session, payload, confirmed_by=user)


@app.post("/api/orders/status", response_model=StatusChangeResult)
def advance_status_route(
    payload: StatusChangeIn, session: SessionDep, who: CurrentDep
) -> StatusChangeResult:
    """Moves an order along the pipeline. SPEC.md 6.3.

    The device has already made the move locally; this re-validates it against
    the same rules, from the same shared fixtures, and applies it.

    **Idempotent on the event id**, not on the order -- an order walks the
    pipeline many times, so what must not happen twice is one particular move.

    A refusal comes back 200 with `refused_because` set, not as an error. The
    device is offline-first and may be hours ahead of the server; it needs to
    know which move was rejected and why, rather than lose a batch to a 400.
    """
    user, _ = who
    return advance_order_status(session, payload, by=user)


@app.post("/api/orders/buyer", response_model=BuyerDetailsResult)
def push_buyer_details_route(
    payload: BuyerDetailsIn, session: SessionDep, who: CurrentDep
) -> BuyerDetailsResult:
    """Records what was captured about the buyer. SPEC.md 10.3.

    Its own push rather than a field on the order, because an order is pushed
    once at confirmation and these are captured after measurement.

    It MERGES: a field the payload does not carry keeps whatever is stored, so
    the measurer's TIN and the office's address end up on one row instead of
    overwriting each other. An empty string clears a field; a push older than
    the stored capture is refused as stale rather than applied.

    Nothing here decides whether the details were needed -- that is the
    threshold rule, checked when the order tries to move. What comes back is
    whether the record is now complete, from the same rule the handset shows.
    """
    _ = who
    return push_buyer_details(session, payload)


@app.post("/api/orders/measurement", response_model=MeasurementResult)
def push_measurement_route(
    payload: MeasurementIn, session: SessionDep, who: CurrentDep
) -> MeasurementResult:
    """Records a site measurement pushed up after the device took it.
    SPEC.md §11 Phase 6.

    Its own push, for the same reason buyer details get one: an order is
    pushed once at confirmation, before the site visit happens, and a retry
    of that push is treated as a pure duplicate that never touches its lines
    again.

    Staled on the LINE's own measured_at, not the order's, so one line being
    remeasured never refuses a push about a different line. Reprices the
    whole order, so its stored total never drifts out of step with the lines
    under it.
    """
    user, _ = who
    return push_measurement(session, payload, by=user)


@app.post("/api/locks", response_model=LockPushResult)
def push_lock_route(
    payload: CategoryLockIn, session: SessionDep, who: CurrentDep
) -> LockPushResult:
    """Accepts a hold opened on a handset. SPEC.md 6.1.

    Idempotent on the device's own lock id: the RM300 was taken before this row
    existed, so a retry must not produce a second hold for one deposit.

    Nothing here re-decides whether the hold was allowed. The device already
    refused outside a fair and below the minimum, at the moment the money
    changed hands, and refusing it now would leave a customer who has paid
    RM300 holding nothing.
    """
    user, _ = who
    return push_category_lock(session, payload, opened_by=user)


@app.get("/api/locks", response_model=LocksOut)
def locks_route(customer_key: str, session: SessionDep, who: CurrentDep) -> LocksOut:
    """Every hold this customer still has. SPEC.md 6.1.

    The lookup a handset makes when it learns a phone number. Without it a hold
    is one handset's secret: six phones work a fair, the customer deposits on
    phone 3, and walks into the showroom in March where phone 1 is used.

    Expiry is not filtered server-side. The resolver decides whether a hold is
    still good against the date it is pricing on, and a handset that has been
    offline for a week needs the row to make that judgement itself.
    """
    _ = who
    return LocksOut(
        locks=[
            CategoryLockOut(
                id=lock.id,
                customer_key=lock.customer_key,
                category=lock.category,
                held_rate_card_version=lock.held_rate_card_version,
                held_discount_pct=lock.held_discount_pct,
                held_until=lock.held_until,
                status=lock.status,
            )
            for lock in locks_for_customer(session, customer_key)
        ]
    )


@app.post("/api/deposit-prompts", response_model=DepositPromptResult)
def push_prompt_route(
    payload: DepositPromptIn, session: SessionDep, who: CurrentDep
) -> DepositPromptResult:
    """Accepts one answer to the category prompt. SPEC.md 6.2.

    Append-only and idempotent. The declined-deposit report only tells the boss
    what fairs are leaving on the table if a decline reaches the server as
    reliably as a sale does.
    """
    user, _ = who
    return push_deposit_prompt(session, payload, by=user)


@app.get("/api/orders", response_model=OrdersOut)
def orders_route(
    session: SessionDep,
    who: CurrentDep,
    status_filter: str | None = Query(default=None, alias="status"),
    channel: str | None = None,
    confirmed_from: datetime | None = None,
    confirmed_to: datetime | None = None,
    limit: int = Query(default=MAX_PAGE, ge=1, le=MAX_PAGE),
    offset: int = Query(default=0, ge=0),
) -> OrdersOut:
    """The order board. SPEC.md 11 Phase 5.

    Filters combine and are all optional. `confirmed_from` is inclusive and
    `confirmed_to` exclusive, so one order lands in exactly one period.

    Sorted by how soon a hold runs out, nulls last: a hold that expires unused
    is a customer who paid RM300 and got nothing, so those are the cards that
    have to be at the top.

    `total` is what matches the filter, not what is on this page -- a board that
    cannot say "50 of 512" leaves somebody guessing whether the filter worked.
    """
    _ = who
    orders, total = list_orders(
        session,
        status=status_filter,
        channel=channel,
        confirmed_from=confirmed_from,
        confirmed_to=confirmed_to,
        limit=limit,
        offset=offset,
    )
    return OrdersOut(orders=orders, total=total)


@app.get("/api/orders/{order_id}", response_model=OrderDetailOut)
def order_detail_route(
    order_id: str, session: SessionDep, who: CurrentDep
) -> OrderDetailOut:
    """One order, with its lines, its history and every price moved by hand.

    All in one response: somebody looking at an order is almost always
    answering "why is this number what it is", and three round trips to answer
    that is three chances to give up.
    """
    _ = who
    detail = order_detail(session, order_id)
    if detail is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such order")
    return detail


@app.get("/api/measurement-queue", response_model=MeasurementQueueOut)
def measurement_queue_route(
    session: SessionDep, who: CurrentDep
) -> MeasurementQueueOut:
    """What is waiting for a site visit. SPEC.md 11 Phase 5.

    Grouped into trips and ordered by who has waited longest -- not by hold
    expiry the way the order board is. An order pinned its rate card version
    when the deposit confirmed it, so measuring it late does not reprice it;
    what is urgent here is a person who paid in July and has had no phone call.

    The clock is read once, here, and passed down. Two groups computed against
    two different "now" values could disagree about the same day.
    """
    _ = who
    return measurement_queue(session, now=datetime.now(UTC))


@app.get("/api/overrides", response_model=OverridesOut)
def overrides_route(
    start: datetime, end: datetime, session: SessionDep, admin: AdminDep
) -> OverridesOut:
    """Every price moved by hand in a window. SPEC.md 6.5.

    Admin only. The log names people, and it is the control on a power only
    admins have -- handing it to everybody would make it a leaderboard.
    """
    _ = admin
    return OverridesOut(overrides=overrides_between(session, start=start, end=end))


@app.get("/api/deposit-prompts", response_model=DepositPromptsOut)
def prompts_route(
    start: datetime, end: datetime, session: SessionDep, admin: AdminDep
) -> DepositPromptsOut:
    """Every answer to the category prompt in a window. SPEC.md 6.2.

    Raw rows, not a summary. The dashboard will want to slice these by
    salesperson and by fair, and aggregating here would mean two summaries that
    have to agree and eventually will not.
    """
    _ = admin
    return DepositPromptsOut(prompts=prompts_between(session, start=start, end=end))


@app.get("/api/reports/variance", response_model=VarianceReport)
def variance_route(session: SessionDep, admin: AdminDep) -> VarianceReport:
    """Estimate against the tape, per salesperson. SPEC.md 6.3, 11 Phase 5.

    Admin only. It names people and ranks them, which is the same reason the
    override review is admin only -- handed to everybody it becomes a
    leaderboard, and the point of it is a training conversation.

    Read it knowing the whole column is biased: a quotation rounds every
    quantity up and the final bill uses the exact tape, so an honest estimate
    always comes in high. What identifies a bad guesser is being much further
    out than everybody else.
    """
    _ = admin
    return variance_by_salesperson(session)


@app.get("/api/reports/fairs", response_model=FairReport)
def fairs_route(session: SessionDep, admin: AdminDep) -> FairReport:
    """What each fair did. SPEC.md 11 Phase 5.

    Grouped on the promo code of the card an order pinned: the channel says an
    order came from a fair, the pinned version says which one.
    """
    _ = admin
    return fair_performance(session)


@app.get("/api/reports/balances", response_model=BalancesReport)
def balances_route(session: SessionDep, admin: AdminDep) -> BalancesReport:
    """Money still to come, aged by how long since the deposit. 11 Phase 5.

    Nothing here is called overdue: there is no invoice date and no payment
    terms in this system, so it cannot know when a balance falls due (13 C11).

    Every row says whether its total is a final price or still the quotation.
    An estimate is an upper bound (8.5), so an estimated balance is the most
    that could be owed rather than a debt.
    """
    _ = admin
    return outstanding_balances(session, now=datetime.now(UTC))


@app.post("/api/rate-cards/preview", response_model=CardDiffOut)
def preview_card_route(
    payload: PreviewIn, session: SessionDep, admin: AdminDep
) -> CardDiffOut:
    """What publishing this card would change. SPEC.md 11 Phase 5.

    The acceptance criterion is that publishing shows exactly which products
    move and by how much *before* commit. Nobody publishes 77 rows and hopes.

    Computed here rather than in the dashboard, because the server is the
    authority on pricing: a diff worked out in the browser would be a different
    implementation from the one that decides what actually lands, and a preview
    people learn not to trust is worse than none.

    Changes nothing. Admin only, like publishing itself.
    """
    _ = admin
    live = active_card(session, payload.list_id)
    diff = diff_cards(
        None if live is None else live.payload,
        payload.payload,
        language=payload.language,
    )

    def out(change) -> RateChangeOut:
        return RateChangeOut(
            rule_id=change.rule_id,
            label=change.label,
            old_rate_sen=change.old_rate_sen,
            new_rate_sen=change.new_rate_sen,
            old_mvp_rate_sen=change.old_mvp_rate_sen,
            new_mvp_rate_sen=change.new_mvp_rate_sen,
            delta_sen=change.delta_sen,
        )

    return CardDiffOut(
        changed=[out(c) for c in diff.changed],
        added=[out(c) for c in diff.added],
        removed=[out(c) for c in diff.removed],
        unchanged=diff.unchanged,
        is_empty=diff.is_empty,
        total_delta_sen=diff.total_delta_sen,
    )


def _person_out(user: User) -> PersonOut:
    return PersonOut(
        id=user.id,
        name=user.name,
        phone=user.phone,
        email=user.email,
        role=user.role,
        language=user.language,
        is_active=user.is_active,
        deactivated_at=user.deactivated_at,
    )


@app.get("/api/people", response_model=PeopleOut)
def people_route(session: SessionDep, admin: AdminDep) -> PeopleOut:
    """Everybody who can sign in, and everybody who used to. SPEC.md 11 Phase 5.

    Leavers included on purpose: a list that hides them cannot answer "who used
    to have access", which is the question somebody asks after something goes
    missing.
    """
    _ = admin
    return PeopleOut(people=[_person_out(u) for u in list_people(session)])


@app.post("/api/people", response_model=PersonOut, status_code=status.HTTP_201_CREATED)
def add_person_route(
    payload: AddPersonIn, session: SessionDep, admin: AdminDep
) -> PersonOut:
    """Creates somebody who can sign in. SPEC.md 12.

    The *first* admin still needs shell access -- there is no register endpoint
    and no bootstrap password in the image. This only saves an admin from a
    terminal for the second person onwards, which lowers no bar, and raises a
    real one: without it the boss keeps one shared login that reaches every
    handset, which 6.5 says happens within a month.

    The PIN is hashed and never returned. A weak one is refused before anything
    is written, so a refusal leaves no half-made user behind.
    """
    _ = admin
    try:
        user = add_person(
            session,
            name=payload.name,
            phone=payload.phone,
            pin=payload.pin,
            role=payload.role,
            email=payload.email,
            language=payload.language,
        )
    except PhoneTaken as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    except (WeakPin, BadRole) as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc

    return _person_out(user)


@app.post("/api/people/{user_id}/pin", response_model=PersonOut)
def set_pin_route(
    user_id: str, payload: SetPinIn, session: SessionDep, admin: AdminDep
) -> PersonOut:
    """Changes somebody's PIN. The old one stops working immediately."""
    _ = admin
    try:
        return _person_out(set_pin(session, user_id, payload.pin))
    except NoSuchUser as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such user") from exc
    except WeakPin as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc


@app.post("/api/people/{user_id}/deactivate", response_model=DeactivateOut)
def deactivate_route(
    user_id: str, session: SessionDep, admin: AdminDep
) -> DeactivateOut:
    """Ends somebody's access. SPEC.md 12.

    Never deletes -- their quotes and payments still name them. What goes is
    every live session: sessions never expire, so without this the handset in a
    leaver's pocket keeps working forever.

    An admin cannot deactivate themselves. Locking the last admin out of the
    box is a mistake nobody can undo from the app, and the alternative is a
    trip to the server with a shell.
    """
    if admin.id == user_id:
        raise HTTPException(
            HTTP_422_UNPROCESSABLE,
            "you cannot deactivate yourself",
        )

    try:
        person, killed = deactivate(session, user_id)
    except NoSuchUser as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such user") from exc

    return DeactivateOut(person=_person_out(person), sessions_revoked=killed)


@app.post("/api/people/{user_id}/reactivate", response_model=PersonOut)
def reactivate_route(user_id: str, session: SessionDep, admin: AdminDep) -> PersonOut:
    """Lets somebody back in.

    Their old sessions stay revoked, so coming back means signing in again --
    and a handset that was out of their hands does not silently start working.
    """
    _ = admin
    try:
        return _person_out(reactivate(session, user_id))
    except NoSuchUser as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such user") from exc


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

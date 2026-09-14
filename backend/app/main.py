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

import base64
import binascii
import time
from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Annotated

from fastapi import (
    Depends,
    FastAPI,
    File,
    Header,
    HTTPException,
    Path,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from .api.schemas import (
    AddPersonIn,
    AdjustStockIn,
    AllocationOut,
    AllocationsOut,
    ApproveAllocationIn,
    BalancesReport,
    BundleOut,
    BuyerDetailsIn,
    BuyerDetailsResult,
    CalibrateFloorPlanIn,
    CardDiffOut,
    CategoryLockIn,
    CategoryLockOut,
    DeactivateOut,
    DepositPromptIn,
    DepositPromptResult,
    DepositPromptsOut,
    ExtractionOut,
    FairReport,
    FloorPlanOut,
    LockPushResult,
    LocksOut,
    LoginIn,
    ManualAllocationIn,
    MaterialIn,
    MaterialOut,
    MaterialsOut,
    MeasurementIn,
    MeasurementQueueOut,
    MeasurementResult,
    NewVersionIn,
    OpeningOut,
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
    ProductOut,
    ProductPriceEditIn,
    ProductPriceEditOut,
    ProductsOut,
    ProjectIn,
    ProjectOut,
    ProjectsOut,
    ProposedOpeningOut,
    ProposedRoomOut,
    PublishIn,
    PublishOut,
    PushResult,
    QuoteIn,
    RateChangeOut,
    ReceiveStockIn,
    RecognizeIn,
    RejectAllocationIn,
    RejectUnitTypeIn,
    ReleaseAllocationIn,
    ReorderAlertOut,
    ReorderAlertsOut,
    RoomOut,
    SessionOut,
    SetLanguageIn,
    SetPinIn,
    StatusChangeIn,
    StatusChangeResult,
    StockLotOut,
    StockLotsOut,
    StockMovementOut,
    UnitTypeCreateIn,
    UnitTypeDetailOut,
    UnitTypeOut,
    UnitTypesOut,
    UnitTypeSubmissionIn,
    UnitTypeSubmissionResult,
    UnitTypeVersionOut,
    UnitTypeWithVersionsOut,
    UserOut,
    VarianceReport,
)
from .api.schemas import (
    FloorPlanIn as FloorPlanApiIn,
)
from .api.schemas import (
    OpeningIn as OpeningApiIn,
)
from .api.schemas import (
    RoomIn as RoomApiIn,
)
from .core.rate_limit import RateLimiter, RateLimitRule
from .core.security import WeakPin
from .db import session_scope
from .models.db import (
    Allocation,
    DeviceSession,
    FloorPlan,
    Material,
    Opening,
    OrderLine,
    Project,
    Room,
    StockLot,
    StockMovement,
    UnitType,
    UnitTypeVersion,
    User,
)
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
    NoSuchProduct,
    RateEditRefused,
    UnknownRateCardVersion,
    active_card,
    advance_order_status,
    edit_product_price,
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
from .services.inventory import (
    DuplicateMaterialCode,
    NoSuchAllocation,
    adjust_stock,
    approve_allocation,
    create_manual_allocation,
    create_material,
    deactivate_material,
    list_materials,
    pending_allocations,
    receive_stock,
    reject_allocation,
    release_allocation,
    reorder_alerts,
)
from .services.inventory import (
    NoSuchLot as NoSuchStockLot,
)
from .services.inventory import (
    NoSuchMaterial as NoSuchMaterialForStock,
)
from .services.inventory import (
    WrongStatus as AllocationWrongStatus,
)
from .services.library import (
    ALLOWED_FLOOR_PLAN_CONTENT_TYPES,
    NoSuchFloorPlan,
    NoSuchProject,
    NoSuchUnitType,
    NoVersionYet,
    WrongStatus,
    add_corrected_version,
    approve_unit_type,
    calibrate_floor_plan,
    create_project,
    create_unit_type,
    floor_plan_detail,
    list_unit_types,
    recognize_floor_plan_image,
    reject_unit_type,
    search_projects,
    submit_for_review,
    submit_from_device,
    unit_type_detail,
    upload_floor_plan,
)
from .services.library import (
    FloorPlanImageIn as FloorPlanImageServiceIn,
)
from .services.library import (
    FloorPlanIn as FloorPlanServiceIn,
)
from .services.library import (
    OpeningIn as OpeningServiceIn,
)
from .services.library import (
    RoomIn as RoomServiceIn,
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
    set_language,
    set_pin,
)
from .services.reads import (
    MAX_PAGE,
    allocation_out,
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

#: See `app.core.rate_limit`'s own docstring for why a plain in-process dict
#: is correct here and would not be if this ever ran as more than one worker.
_rate_limiter = RateLimiter()
#: Tighter than the general rule: login is the one unauthenticated route that
#: touches data, and it is what a phone-and-PIN spray targets. This is a
#: second layer over `app.services.auth`'s own per-*phone* backoff, not a
#: replacement for it -- this one catches an attacker rotating through many
#: numbers from one source, which never touches any single number's counter
#: twice.
_LOGIN_RULE = RateLimitRule(limit=20, window_seconds=60)
#: A generous ceiling nothing in normal use -- a handful of handsets syncing,
#: one dashboard -- comes anywhere near. Purely a backstop against a single
#: source hammering the API, scraping data or running the server hot.
_GLOBAL_RULE = RateLimitRule(limit=300, window_seconds=60)


def reset_rate_limits() -> None:
    """Test-only. `_rate_limiter` is a module-level singleton bound to this
    `app` object, which every test file's `client` fixture reuses -- without
    a reset between tests, one test's burst of requests silently counts
    against the next test's limit."""
    _rate_limiter.reset()


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    """`/api/health` is exempt: it is what the container health check and an
    external uptime monitor both call, unauthenticated, on a schedule
    neither of them will back off from."""
    if request.url.path == "/api/health":
        return await call_next(request)

    client_ip = request.client.host if request.client else "unknown"
    now = time.monotonic()

    rules = [("global", _GLOBAL_RULE)]
    if request.url.path == "/api/auth/login":
        rules.append(("login", _LOGIN_RULE))

    retry_after = None
    for name, rule in rules:
        wait = _rate_limiter.check(name, client_ip, rule, now=now)
        if wait is not None:
            retry_after = wait if retry_after is None else max(retry_after, wait)

    if retry_after is not None:
        return JSONResponse(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            content={"detail": "too many requests"},
            headers={"Retry-After": str(int(retry_after) + 1)},
        )

    return await call_next(request)


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
    """Admin only. §3: part-timers never see a rate at all. Staff can see
    rates and, since the live per-product price edit below, can change one
    directly -- but only an admin may publish a whole new card."""
    user, _ = who
    if user.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="admin only",
        )
    return user


AdminDep = Annotated[User, Depends(require_admin)]


def require_staff_or_admin(who: CurrentDep) -> User:
    """Staff or admin. Loosened from admin-only: a live single-product price
    edit is meant to be usable by whoever is standing at a fair table
    reacting to a competitor, not only an admin who has to be reached by
    phone first. Part-timers are still excluded -- hard rule 8, they never
    see a rate at all."""
    user, _ = who
    if user.role not in ("staff", "admin"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="staff or admin only",
        )
    return user


StaffOrAdminDep = Annotated[User, Depends(require_staff_or_admin)]


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


@app.post("/api/auth/language", response_model=UserOut)
def set_my_language(
    payload: SetLanguageIn, session: SessionDep, who: CurrentDep
) -> UserOut:
    """A person picking their own language. Self-service, unlike everything
    else that changes a `User` row: no admin check, because reading this
    system in your own language needs nobody else's permission.

    SPEC.md §13 C9 — switchable per user, not per device. It follows the
    account rather than the browser: the next machine that person signs into
    picks it straight back up.
    """
    user, _ = who
    updated = set_language(session, user.id, payload.language)
    return UserOut(
        id=updated.id, name=updated.name, role=updated.role, language=updated.language
    )


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


@app.get("/api/rate-cards/{list_id}/products", response_model=ProductsOut)
def list_products_route(
    list_id: Annotated[str, Path(pattern="^(fair|standard)$")],
    session: SessionDep,
    who: StaffOrAdminDep,
) -> ProductsOut:
    """The active card's products, for the live per-product price screen.
    Staff or admin -- part-timers never see a rate at all (hard rule 8).
    """
    _ = who
    card = active_card(session, list_id)
    if card is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no active rate card")
    return ProductsOut(
        list_id=list_id,
        version=card.version,
        products=[
            ProductOut(
                id=r["id"],
                family=r["family"],
                variant=r["variant"],
                material_key=r.get("material_key"),
                labels=r.get("labels", {}),
                basis=r["basis"],
                rate_sen=r["rate_sen"],
                mvp_rate_sen=r.get("mvp_rate_sen"),
                provisional=bool(r.get("provisional", False)),
            )
            for r in card.payload.get("rules", [])
        ],
    )


@app.post(
    "/api/rate-cards/{list_id}/products/{rule_id}/price",
    response_model=ProductPriceEditOut,
)
def edit_product_price_route(
    list_id: Annotated[str, Path(pattern="^(fair|standard)$")],
    rule_id: str,
    payload: ProductPriceEditIn,
    session: SessionDep,
    who: StaffOrAdminDep,
) -> ProductPriceEditOut:
    """Changes one product's price directly, live immediately. Staff or
    admin, mandatory reason -- SPEC.md §6.5's own discipline for an
    order-line override, applied here to a catalog price: the gate is a
    speed bump, the audit row read back later is the actual control.

    No whole-card upload, no preview step. Still publishes a new
    `RateCardVersion` under the hood rather than editing a row in place, so
    a quote already priced at the old rate stays explainable.
    """
    try:
        edit = edit_product_price(
            session,
            list_id=list_id,
            rule_id=rule_id,
            rate_sen=payload.rate_sen,
            mvp_rate_sen=payload.mvp_rate_sen,
            reason=payload.reason,
            by_user_id=who.id,
        )
    except NoSuchProduct as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such product") from exc
    except RateEditRefused as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, exc.reason.value) from exc

    return ProductPriceEditOut(
        rule_id=edit.rule_id,
        list_id=edit.list_id,
        version=edit.resulting_version,
        rate_sen=edit.after_rate_sen,
        mvp_rate_sen=edit.after_mvp_rate_sen,
        edited_by=edit.by_user_id,
        at=edit.at,
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
    confirmed_by_user_id: str | None = None,
    confirmed_from: datetime | None = None,
    confirmed_to: datetime | None = None,
    limit: int = Query(default=MAX_PAGE, ge=1, le=MAX_PAGE),
    offset: int = Query(default=0, ge=0),
) -> OrdersOut:
    """The order board. SPEC.md 11 Phase 5.

    Filters combine and are all optional. `confirmed_from` is inclusive and
    `confirmed_to` exclusive, so one order lands in exactly one period.
    `confirmed_by_user_id` is the salesperson filter -- SPEC.md's own
    wishlist names it alongside channel, and it is a plain equality on a
    column `Order` already carries, unlike "fair" or "project", which need
    a real design decision before they are a filter rather than a guess.

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
        confirmed_by_user_id=confirmed_by_user_id,
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


# --- Property / Project / Unit Library. SPEC.md Phase 8. -------------------


def _project_out(project: Project) -> ProjectOut:
    return ProjectOut(
        id=project.id,
        name=project.name,
        developer=project.developer,
        area=project.area,
        created_at=project.created_at,
    )


def _unit_type_out(unit_type: UnitType) -> UnitTypeOut:
    return UnitTypeOut(
        id=unit_type.id,
        project_id=unit_type.project_id,
        project_name=unit_type.project.name,
        name=unit_type.name,
        floor_count=unit_type.floor_count,
        variant_of=unit_type.variant_of,
        status=unit_type.status,
        created_by_user_id=unit_type.created_by_user_id,
        created_at=unit_type.created_at,
        updated_at=unit_type.updated_at,
    )


def _opening_out(opening: Opening) -> OpeningOut:
    return OpeningOut(
        id=opening.id,
        label=opening.label,
        room=opening.room,
        floor=opening.floor,
        nominal_w_tmm=opening.nominal_w_tmm,
        nominal_h_tmm=opening.nominal_h_tmm,
        sort_order=opening.sort_order,
    )


def _room_out(room: Room) -> RoomOut:
    return RoomOut(
        id=room.id,
        name=room.name,
        floor=room.floor,
        nominal_area_mm2=room.nominal_area_mm2,
        skirting_run_tmm=room.skirting_run_tmm,
    )


def _floor_plan_out(plan: FloorPlan) -> FloorPlanOut:
    return FloorPlanOut(
        id=plan.id,
        file_ref=plan.file_ref,
        content_type=plan.content_type,
        scale_tmm_per_px=plan.scale_tmm_per_px,
        uploaded_by_user_id=plan.uploaded_by_user_id,
        uploaded_at=plan.uploaded_at,
    )


def _version_out(version: UnitTypeVersion) -> UnitTypeVersionOut:
    return UnitTypeVersionOut(
        id=version.id,
        version=version.version,
        approved_by_user_id=version.approved_by_user_id,
        approved_at=version.approved_at,
        rejected_by_user_id=version.rejected_by_user_id,
        rejected_at=version.rejected_at,
        rejection_reason=version.rejection_reason,
        note=version.note,
        openings=[
            _opening_out(o)
            for o in sorted(version.openings, key=lambda o: o.sort_order)
        ],
        rooms=[_room_out(r) for r in version.rooms],
        floor_plan=_floor_plan_out(version.floor_plan) if version.floor_plan else None,
    )


def _detail_out(unit_type: UnitType) -> UnitTypeDetailOut:
    return UnitTypeDetailOut(
        unit_type=_unit_type_out(unit_type),
        versions=[_version_out(v) for v in unit_type.versions],
    )


def _with_versions_out(unit_type: UnitType) -> UnitTypeWithVersionsOut:
    return UnitTypeWithVersionsOut(
        **_unit_type_out(unit_type).model_dump(),
        versions=[_version_out(v) for v in unit_type.versions],
    )


def _service_openings(openings: list[OpeningApiIn]) -> list[OpeningServiceIn]:
    return [
        OpeningServiceIn(
            label=o.label,
            room=o.room,
            nominal_w_tmm=o.nominal_w_tmm,
            nominal_h_tmm=o.nominal_h_tmm,
            floor=o.floor,
            sort_order=o.sort_order,
        )
        for o in openings
    ]


def _service_rooms(rooms: list[RoomApiIn]) -> list[RoomServiceIn]:
    return [
        RoomServiceIn(
            name=r.name,
            nominal_area_mm2=r.nominal_area_mm2,
            floor=r.floor,
            skirting_run_tmm=r.skirting_run_tmm,
        )
        for r in rooms
    ]


def _service_floor_plan(plan: FloorPlanApiIn | None) -> FloorPlanServiceIn | None:
    if plan is None:
        return None
    return FloorPlanServiceIn(
        file_ref=plan.file_ref, scale_tmm_per_px=plan.scale_tmm_per_px
    )


@app.post(
    "/api/projects", response_model=ProjectOut, status_code=status.HTTP_201_CREATED
)
def create_project_route(
    payload: ProjectIn, session: SessionDep, who: CurrentDep
) -> ProjectOut:
    """A development, so its unit types have somewhere to live.

    Not admin-only: creating the shell a unit type lives under is ordinary
    data entry, the same trust level as adding a quote or a payment.
    """
    _ = who
    return _project_out(
        create_project(
            session, name=payload.name, developer=payload.developer, area=payload.area
        )
    )


@app.get("/api/projects", response_model=ProjectsOut)
def search_projects_route(
    session: SessionDep, who: CurrentDep, q: str | None = None
) -> ProjectsOut:
    """What a salesperson finds by typing an area or a development name."""
    _ = who
    return ProjectsOut(
        projects=[_project_out(p) for p in search_projects(session, query=q)]
    )


@app.post(
    "/api/unit-types",
    response_model=UnitTypeDetailOut,
    status_code=status.HTTP_201_CREATED,
)
def create_unit_type_route(
    payload: UnitTypeCreateIn, session: SessionDep, who: CurrentDep
) -> UnitTypeDetailOut:
    """Digitises a floor plan once. SPEC.md Phase 8.

    ``submit=true`` is the part-timer's one-shot path, straight to
    ``pending_review``. Anybody signed in may create one -- the gate that
    matters is on *approval*, not on who may draft or submit.
    """
    user, _ = who
    try:
        unit_type = create_unit_type(
            session,
            project_id=payload.project_id,
            name=payload.name,
            floor_count=payload.floor_count,
            variant_of=payload.variant_of,
            created_by_user_id=user.id,
            openings=_service_openings(payload.openings),
            rooms=_service_rooms(payload.rooms),
            floor_plan=_service_floor_plan(payload.floor_plan),
            submit=payload.submit,
        )
    except NoSuchProject as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such project") from exc

    return _detail_out(unit_type_detail(session, unit_type.id))


@app.get("/api/unit-types", response_model=UnitTypesOut)
def list_unit_types_route(
    session: SessionDep,
    who: CurrentDep,
    project_id: str | None = None,
    status_filter: str | None = Query(default=None, alias="status"),
) -> UnitTypesOut:
    _ = who
    return UnitTypesOut(
        unit_types=[
            _with_versions_out(u)
            for u in list_unit_types(
                session, project_id=project_id, status=status_filter
            )
        ]
    )


@app.get("/api/unit-types/{unit_type_id}", response_model=UnitTypeDetailOut)
def unit_type_detail_route(
    unit_type_id: str, session: SessionDep, who: CurrentDep
) -> UnitTypeDetailOut:
    _ = who
    detail = unit_type_detail(session, unit_type_id)
    if detail is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such unit type")
    return _detail_out(detail)


@app.post("/api/unit-types/{unit_type_id}/submit", response_model=UnitTypeOut)
def submit_unit_type_route(
    unit_type_id: str, session: SessionDep, who: CurrentDep
) -> UnitTypeOut:
    """The part-timer path, when the submission was not made in one shot:
    ``draft`` -> ``pending_review``."""
    _ = who
    try:
        return _unit_type_out(submit_for_review(session, unit_type_id))
    except NoSuchUnitType as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such unit type") from exc
    except WrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc


@app.post("/api/unit-types/{unit_type_id}/approve", response_model=UnitTypeOut)
def approve_unit_type_route(
    unit_type_id: str, session: SessionDep, admin: AdminDep
) -> UnitTypeOut:
    """Makes the latest version live in the library. Admin only, per the
    workflow diagram naming ADMIN as who approves either path."""
    try:
        return _unit_type_out(
            approve_unit_type(session, unit_type_id, by_user_id=admin.id)
        )
    except NoSuchUnitType as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such unit type") from exc
    except WrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc


@app.post("/api/unit-types/{unit_type_id}/reject", response_model=UnitTypeOut)
def reject_unit_type_route(
    unit_type_id: str,
    payload: RejectUnitTypeIn,
    session: SessionDep,
    admin: AdminDep,
) -> UnitTypeOut:
    """Sends a part-timer's submission back, with a reason on record. Admin
    only, same as approval."""
    try:
        return _unit_type_out(
            reject_unit_type(
                session, unit_type_id, by_user_id=admin.id, reason=payload.reason
            )
        )
    except NoSuchUnitType as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such unit type") from exc
    except WrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc


@app.post("/api/unit-types/{unit_type_id}/versions", response_model=UnitTypeDetailOut)
def new_version_route(
    unit_type_id: str, payload: NewVersionIn, session: SessionDep, who: CurrentDep
) -> UnitTypeDetailOut:
    """The plan changed. A new version, never an edit to the old one."""
    user, _ = who
    try:
        add_corrected_version(
            session,
            unit_type_id,
            created_by_user_id=user.id,
            openings=_service_openings(payload.openings),
            rooms=_service_rooms(payload.rooms),
            floor_plan=_service_floor_plan(payload.floor_plan),
            note=payload.note,
        )
    except NoSuchUnitType as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such unit type") from exc

    return _detail_out(unit_type_detail(session, unit_type_id))


@app.post("/api/unit-types/{unit_type_id}/floor-plan", response_model=FloorPlanOut)
async def upload_floor_plan_route(
    unit_type_id: str,
    session: SessionDep,
    who: CurrentDep,
    file: Annotated[UploadFile, File()],
) -> FloorPlanOut:
    """The original document, kept alongside the numbers typed from it.
    SPEC.md Phase 8.

    Refuses onto an already-approved version -- a correction to the image
    is a new version, via `POST .../versions`, not an edit in place.
    """
    _ = who
    image_data = await file.read()
    try:
        plan = upload_floor_plan(
            session,
            unit_type_id,
            filename=file.filename or "floor-plan",
            content_type=file.content_type or "application/octet-stream",
            image_data=image_data,
            uploaded_by_user_id=who[0].id,
        )
    except NoSuchUnitType as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such unit type") from exc
    except NoVersionYet as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    except WrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc

    return _floor_plan_out(plan)


@app.get("/api/floor-plans/{floor_plan_id}/image")
def floor_plan_image_route(
    floor_plan_id: str, session: SessionDep, who: CurrentDep
) -> Response:
    """The bytes themselves. Never embedded in a JSON response -- this is
    the one place they leave the server."""
    _ = who
    plan = floor_plan_detail(session, floor_plan_id)
    if plan is None or plan.image_data is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such image")
    # Upload already refuses anything outside this allowlist; re-checking on
    # the way out is what stops a row from an older, less careful build (or
    # a direct DB edit) from being served as a document a browser executes
    # rather than a picture it draws.
    if plan.content_type in ALLOWED_FLOOR_PLAN_CONTENT_TYPES:
        media_type = plan.content_type
    else:
        media_type = "application/octet-stream"
    return Response(
        content=plan.image_data,
        media_type=media_type,
        headers={"X-Content-Type-Options": "nosniff"},
    )


@app.post("/api/floor-plans/{floor_plan_id}/calibrate", response_model=FloorPlanOut)
def calibrate_floor_plan_route(
    floor_plan_id: str,
    payload: CalibrateFloorPlanIn,
    session: SessionDep,
    who: CurrentDep,
) -> FloorPlanOut:
    """Two tapped points, turned into an exact scale. SPEC.md Phase 8."""
    _ = who
    try:
        plan = calibrate_floor_plan(
            session,
            floor_plan_id,
            pixel_distance=payload.pixel_distance,
            real_distance_tmm=payload.real_distance_tmm,
        )
    except NoSuchFloorPlan as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such floor plan") from exc

    return _floor_plan_out(plan)


@app.post("/api/recognize", response_model=ExtractionOut)
def recognize_route(
    payload: RecognizeIn, session: SessionDep, who: CurrentDep
) -> ExtractionOut:
    """Proposes openings and rooms from a floor-plan image. SPEC.md Phase 8,
    "Future: assisted digitisation".

    Stateless and never persisted -- no floor plan id is taken or required,
    so this can run on a photo before it has been submitted anywhere (the
    handset's own "try recognition" step) as well as on one already stored
    (the dashboard's review screen, re-sending the blob it already fetched).
    A proposal is not a version; only a person copying values into the
    submission form, through the existing draft/pending_review/approved
    gate, can create one.
    """
    _ = session, who
    try:
        image_data = base64.b64decode(payload.image_base64, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, "invalid image_base64") from exc

    try:
        result = recognize_floor_plan_image(
            image_data=image_data, content_type=payload.content_type
        )
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc

    return ExtractionOut(
        configured=result.configured,
        provider=result.provider,
        note=result.note,
        openings=[
            ProposedOpeningOut(
                label=o.label,
                room=o.room,
                nominal_w_tmm=o.nominal_w_tmm,
                nominal_h_tmm=o.nominal_h_tmm,
                confidence=o.confidence,
            )
            for o in result.openings
        ],
        rooms=[
            ProposedRoomOut(
                name=r.name,
                nominal_area_mm2=r.nominal_area_mm2,
                confidence=r.confidence,
            )
            for r in result.rooms
        ],
    )


@app.post(
    "/api/unit-type-submissions",
    response_model=UnitTypeSubmissionResult,
    status_code=status.HTTP_201_CREATED,
)
def submit_unit_type_from_device_route(
    payload: UnitTypeSubmissionIn, session: SessionDep, who: CurrentDep
) -> UnitTypeSubmissionResult:
    """The part-timer's offline path, pushed through the outbox like an order
    or a payment. SPEC.md Phase 8.

    **Idempotent on the device's own id** -- `POST /api/orders`'s own
    docstring explains why this shape exists: a retry after a dropped
    fair-tent connection must hand back the same result, not create a second
    submission. Always lands at `pending_review`; an admin still approves or
    rejects it from the same review screen a dashboard-drafted submission
    goes through.
    """
    user, _ = who
    image = None
    if payload.floor_plan is not None:
        try:
            image_data = base64.b64decode(
                payload.floor_plan.image_base64, validate=True
            )
        except (ValueError, binascii.Error) as exc:
            raise HTTPException(HTTP_422_UNPROCESSABLE, "invalid image_base64") from exc
        image = FloorPlanImageServiceIn(
            filename=payload.floor_plan.filename,
            content_type=payload.floor_plan.content_type,
            image_data=image_data,
            pixel_distance=payload.floor_plan.pixel_distance,
            real_distance_tmm=payload.floor_plan.real_distance_tmm,
        )

    try:
        unit_type, duplicate = submit_from_device(
            session,
            id=payload.id,
            project_id=payload.project_id,
            name=payload.name,
            floor_count=payload.floor_count,
            created_by_user_id=user.id,
            openings=_service_openings(payload.openings),
            rooms=_service_rooms(payload.rooms),
            floor_plan_image=image,
        )
    except NoSuchProject as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such project") from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc

    return UnitTypeSubmissionResult(unit_type_id=unit_type.id, duplicate=duplicate)


# ---------------------------------------------------------------------------
# Inventory. SPEC.md Phase 9. Admin-only throughout -- §13 F2's named
# accountable person is an office role, the same one that already owns rate
# cards, overrides and exports.
# ---------------------------------------------------------------------------


def _material_out(material: Material) -> MaterialOut:
    return MaterialOut(
        id=material.id,
        family=material.family,
        variant_compat=list(material.variant_compat or []),
        code=material.code,
        names=material.names,
        uom=material.uom,
        coverage_per_unit=material.coverage_per_unit,
        reorder_level=material.reorder_level,
        is_active=material.is_active,
        created_at=material.created_at,
        updated_at=material.updated_at,
    )


def _stock_lot_out(lot: StockLot) -> StockLotOut:
    return StockLotOut(
        id=lot.id,
        material_id=lot.material_id,
        lot_ref=lot.lot_ref,
        qty_on_hand=lot.qty_on_hand,
        location=lot.location,
        received_at=lot.received_at,
        cost_sen=lot.cost_sen,
    )


def _movement_out(movement: StockMovement) -> StockMovementOut:
    return StockMovementOut(
        id=movement.id,
        material_id=movement.material_id,
        lot_id=movement.lot_id,
        delta=movement.delta,
        reason=movement.reason,
        order_id=movement.order_id,
        by_user_id=movement.by_user_id,
        at=movement.at,
        note=movement.note,
    )


@app.post(
    "/api/materials", response_model=MaterialOut, status_code=status.HTTP_201_CREATED
)
def create_material_route(
    payload: MaterialIn, session: SessionDep, admin: AdminDep
) -> MaterialOut:
    _ = admin
    try:
        material = create_material(
            session,
            family=payload.family,
            variant_compat=payload.variant_compat,
            code=payload.code,
            names=payload.names,
            uom=payload.uom,
            coverage_per_unit=payload.coverage_per_unit,
            reorder_level=payload.reorder_level,
        )
    except DuplicateMaterialCode as exc:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "material code already exists"
        ) from exc
    return _material_out(material)


@app.get("/api/materials", response_model=MaterialsOut)
def list_materials_route(
    session: SessionDep, admin: AdminDep, active_only: bool = True
) -> MaterialsOut:
    _ = admin
    return MaterialsOut(
        materials=[
            _material_out(m) for m in list_materials(session, active_only=active_only)
        ]
    )


@app.post("/api/materials/{material_id}/deactivate", response_model=MaterialOut)
def deactivate_material_route(
    material_id: str, session: SessionDep, admin: AdminDep
) -> MaterialOut:
    _ = admin
    try:
        material = deactivate_material(session, material_id)
    except NoSuchMaterialForStock as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such material") from exc
    return _material_out(material)


@app.post("/api/stock/receive", response_model=StockLotOut)
def receive_stock_route(
    payload: ReceiveStockIn, session: SessionDep, admin: AdminDep
) -> StockLotOut:
    try:
        lot = receive_stock(
            session,
            material_id=payload.material_id,
            lot_ref=payload.lot_ref,
            qty=payload.qty,
            by_user_id=admin.id,
            cost_sen=payload.cost_sen,
            location=payload.location,
            received_at=payload.received_at,
            note=payload.note,
        )
    except NoSuchMaterialForStock as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such material") from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc
    return _stock_lot_out(lot)


@app.get("/api/stock/lots", response_model=StockLotsOut)
def list_stock_lots_route(
    session: SessionDep, admin: AdminDep, material_id: str | None = None
) -> StockLotsOut:
    _ = admin
    stmt = select(StockLot)
    if material_id:
        stmt = stmt.where(StockLot.material_id == material_id)
    stmt = stmt.order_by(StockLot.received_at)
    return StockLotsOut(lots=[_stock_lot_out(lot) for lot in session.scalars(stmt)])


@app.post("/api/stock/adjust", response_model=StockMovementOut)
def adjust_stock_route(
    payload: AdjustStockIn, session: SessionDep, admin: AdminDep
) -> StockMovementOut:
    try:
        movement = adjust_stock(
            session,
            lot_id=payload.lot_id,
            delta=payload.delta,
            reason=payload.reason,
            by_user_id=admin.id,
            note=payload.note,
        )
    except NoSuchStockLot as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such stock lot") from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc
    return _movement_out(movement)


@app.get("/api/allocations", response_model=AllocationsOut)
def list_allocations_route(
    session: SessionDep,
    admin: AdminDep,
    status_filter: str | None = Query(default=None, alias="status"),
) -> AllocationsOut:
    """Defaults to the review queue -- everything `proposed` -- the same
    "the whole control is on this being read" ethos as the library's own
    review screen. Pass `status` to see anything else.
    """
    _ = admin
    if status_filter is None or status_filter == "proposed":
        rows = pending_allocations(session)
    else:
        rows = list(
            session.scalars(
                select(Allocation)
                .where(Allocation.status == status_filter)
                .order_by(Allocation.proposed_at)
            )
        )
    return AllocationsOut(allocations=[allocation_out(a) for a in rows])


@app.post(
    "/api/allocations",
    response_model=AllocationOut,
    status_code=status.HTTP_201_CREATED,
)
def create_manual_allocation_route(
    payload: ManualAllocationIn, session: SessionDep, admin: AdminDep
) -> AllocationOut:
    """An admin allocates directly, already decided -- for a material with
    no exact auto-proposal conversion (§13 F3), or a manual split across a
    second lot.
    """
    order_line = session.get(OrderLine, payload.order_line_id)
    # `order_id` is carried on the payload rather than derived, matching
    # every other write in this API -- but nothing enforced it actually
    # named the line's own order, so a mismatched or made-up id was
    # silently accepted and stored on the allocation, corrupting the one
    # thing a report or a release would trust to say which order used the
    # stock.
    if order_line is None or order_line.order_id != payload.order_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such order line")
    try:
        allocation = create_manual_allocation(
            session,
            order_line_id=payload.order_line_id,
            order_id=payload.order_id,
            material_id=payload.material_id,
            lot_id=payload.lot_id,
            qty=payload.qty,
            by_user_id=admin.id,
        )
    except NoSuchMaterialForStock as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such material") from exc
    except NoSuchStockLot as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such stock lot") from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc
    return allocation_out(allocation)


@app.post("/api/allocations/{allocation_id}/approve", response_model=AllocationOut)
def approve_allocation_route(
    allocation_id: str,
    payload: ApproveAllocationIn,
    session: SessionDep,
    admin: AdminDep,
) -> AllocationOut:
    try:
        allocation = approve_allocation(
            session,
            allocation_id=allocation_id,
            by_user_id=admin.id,
            lot_id=payload.lot_id,
        )
    except NoSuchAllocation as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such allocation") from exc
    except NoSuchStockLot as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such stock lot") from exc
    except AllocationWrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc
    return allocation_out(allocation)


@app.post("/api/allocations/{allocation_id}/reject", response_model=AllocationOut)
def reject_allocation_route(
    allocation_id: str,
    payload: RejectAllocationIn,
    session: SessionDep,
    admin: AdminDep,
) -> AllocationOut:
    try:
        allocation = reject_allocation(
            session,
            allocation_id=allocation_id,
            by_user_id=admin.id,
            reason=payload.reason,
        )
    except NoSuchAllocation as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such allocation") from exc
    except AllocationWrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(HTTP_422_UNPROCESSABLE, str(exc)) from exc
    return allocation_out(allocation)


@app.post("/api/allocations/{allocation_id}/release", response_model=AllocationOut)
def release_allocation_route(
    allocation_id: str,
    payload: ReleaseAllocationIn,
    session: SessionDep,
    admin: AdminDep,
) -> AllocationOut:
    """An order cancelled after stock was set aside for it (§6.6: orders are
    cancellable up to `ready`). Puts the quantity back on the lot it came
    from.
    """
    try:
        allocation = release_allocation(
            session,
            allocation_id=allocation_id,
            by_user_id=admin.id,
            note=payload.note,
        )
    except NoSuchAllocation as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such allocation") from exc
    except NoSuchStockLot as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such stock lot") from exc
    except AllocationWrongStatus as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    return allocation_out(allocation)


@app.get("/api/inventory/alerts", response_model=ReorderAlertsOut)
def reorder_alerts_route(session: SessionDep, admin: AdminDep) -> ReorderAlertsOut:
    """ "Available", not raw on-hand -- on hand minus what is already
    proposed against a confirmed order. Not a forecast (SPEC.md §11
    Phase 9): every number in it is a row this system already has.
    """
    _ = admin
    return ReorderAlertsOut(
        alerts=[
            ReorderAlertOut(
                material=_material_out(a.material),
                on_hand=a.on_hand,
                committed=a.committed,
                available=a.available,
                reorder_level=a.reorder_level,
            )
            for a in reorder_alerts(session)
        ]
    )

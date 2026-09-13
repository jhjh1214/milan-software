"""What crosses the wire. Pydantic, so a malformed push is rejected at the door.

Field names match the device's column names exactly (``*_tmm``, ``*_sen``), so
there is no translation layer to get wrong.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

from ..pricing.price_override import MIN_REASON_LENGTH


class QuoteLineIn(BaseModel):
    id: str = Field(min_length=36, max_length=36)
    sort_order: int
    room: str
    variant: str
    material_key: str | None = None
    layer: str
    parent_line_id: str | None = None
    #: Tenths of a millimetre. Never millimetres. Null only for a
    #: `direct_area_sqft` line -- a saved room's area does not reduce to
    #: one rectangle, so there is nothing honest to put here.
    width_tmm: int | None = Field(default=None, ge=0)
    height_tmm: int | None = Field(default=None, ge=0)
    raw_width: str
    raw_height: str
    #: Exact rational as a string, e.g. "700/3". SPEC.md's property library:
    #: a room-sourced flooring line prices from this instead of
    #: `width_tmm x height_tmm`. Meaningful only alongside `width_tmm=None`.
    direct_area_sqft: str | None = None
    quantity: int = Field(default=1, ge=1)
    #: What the device charged. Compared against the server's own figure, never
    #: trusted in place of it (§9.4).
    device_total_sen: int | None = None


class QuoteIn(BaseModel):
    id: str = Field(min_length=36, max_length=36)
    rate_card_version: int
    tier: str = "standard"
    language: str = "zh"
    customer_name: str | None = None
    customer_phone: str | None = None
    delivery_zone_id: str | None = None
    device_total_sen: int | None = None
    created_at: datetime
    updated_at: datetime
    device_id: str | None = None
    lines: list[QuoteLineIn] = []


class PaymentIn(BaseModel):
    """A payment pushed up from a device. §6.4.

    No ``receipt_no``: the device does not have one and must not invent one.
    """

    id: str = Field(min_length=36, max_length=36)
    quote_id: str = Field(min_length=36, max_length=36)
    category_lock_id: str | None = None
    kind: str = Field(pattern="^(deposit|progress|balance|refund)$")
    #: Always positive. A refund is negative by its `kind`, not by its sign, so
    #: nobody has to remember which rows carry a minus.
    amount_sen: int = Field(gt=0)
    method: str = Field(pattern="^(cash|card_terminal|duitnow|bank_transfer|cheque)$")
    external_ref: str | None = Field(default=None, max_length=80)
    taken_at: datetime
    device_id: str | None = None


class PaymentResult(BaseModel):
    payment_id: str
    #: True when this exact payment had already been accepted. A retry is a
    #: success — the device cannot know whether the first attempt landed, and
    #: taking the same RM300 twice is the failure this prevents.
    duplicate: bool
    #: The number the server issued, first time and every time after. A retry
    #: gets the **same** one back, so a reprinted receipt matches the first.
    receipt_no: str


class LineResult(BaseModel):
    line_id: str
    server_total_sen: int | None
    device_total_sen: int | None
    agreed: bool
    detail: str | None = None


class PushResult(BaseModel):
    quote_id: str
    #: True when this exact quote had already been accepted. A retry is a
    #: success, not an error: the device cannot know whether the first attempt
    #: landed before the signal dropped.
    duplicate: bool
    server_total_sen: int | None
    device_total_sen: int | None
    #: Non-empty means the two engines disagreed. The order is still accepted —
    #: §9.4 never loses a sale over a rounding dispute — and each disagreement
    #: is recorded for an admin to review.
    discrepancies: list[LineResult] = []


class LoginIn(BaseModel):
    """Phone plus PIN, not a name picked from a list.

    A roster on the sign-in screen would hand the staff list to anyone who
    opens the app, and the app is installed on handsets that travel to fairs.
    """

    phone: str = Field(min_length=3, max_length=40)
    pin: str = Field(min_length=1, max_length=12)
    #: The handset's own id, client-generated. Signing in again on the same one
    #: replaces its session rather than adding a second.
    device_id: str = Field(min_length=1, max_length=36)
    device_label: str | None = Field(default=None, max_length=80)


class UserOut(BaseModel):
    id: str
    name: str
    role: str
    language: str


class SessionOut(BaseModel):
    """Returned once, at sign-in. The token is not readable again afterwards —
    only its SHA-256 is stored."""

    token: str
    user: UserOut


class SetLanguageIn(BaseModel):
    """A signed-in person changing their own account's language. SPEC.md §13 C9."""

    language: str = Field(pattern="^(zh|en|ms)$")


class PublishIn(BaseModel):
    """An admin publishing a price list.

    The card arrives whole. A partial update would need a merge, and a merge of
    prices is a way to end up with a card nobody has ever read end to end.
    """

    list_id: str = Field(pattern="^(fair|standard)$")
    payload: dict


class PublishOut(BaseModel):
    version: int
    list_id: str
    published_by: str | None = None


class ProductPriceEditIn(BaseModel):
    """Staff or admin changing one product's live price directly -- no
    whole-card upload, no preview ceremony. `reason` is mandatory for the
    same reason an order-line override's is (SPEC.md §6.5): the log is the
    control, and a row that cannot say why is not an audit trail.

    `mvp_rate_sen` has no default: a product with no MVP substitute sends
    `null` explicitly, and one that has an MVP rate sends its current or
    new value. Defaulting a merely-omitted field to `null` would silently
    clear a real MVP rate the caller never meant to touch -- the same
    absent-vs-empty trap SPEC.md §13 C14 already names for buyer details.
    """

    rate_sen: int = Field(gt=0)
    mvp_rate_sen: int | None = Field(gt=0)
    reason: str = Field(min_length=1, max_length=500)


class ProductPriceEditOut(BaseModel):
    rule_id: str
    list_id: str
    version: int
    rate_sen: int
    mvp_rate_sen: int | None
    edited_by: str
    at: datetime


class ProductOut(BaseModel):
    """One row of the active card, as the dashboard's product list shows
    it -- not the full rate-card row shape, just what an admin or staff
    member needs to see to decide whether this product's price should move.
    """

    id: str
    family: str
    variant: str
    material_key: str | None
    labels: dict[str, str]
    basis: str
    rate_sen: int
    mvp_rate_sen: int | None
    provisional: bool


class ProductsOut(BaseModel):
    list_id: str
    version: int
    products: list[ProductOut] = []


class BundleOut(BaseModel):
    """The reference-data pull. §9.1: replace wholesale, never diff."""

    rate_card_version: int
    list_id: str
    #: Null when the device is already current, so a fair's connection is not
    #: spent re-downloading a card it already has.
    payload: dict | None = None
    up_to_date: bool


class OrderLineIn(BaseModel):
    """One line of a confirmed order, copied off the quote line that priced it.

    Carries the snapshot -- rule, band, version, discount, rate -- because a
    year later the answer to "why did this curtain cost RM552" has to be
    available without reconstructing which card was in force that afternoon.
    """

    id: str = Field(min_length=36, max_length=36)
    quote_line_id: str = Field(min_length=36, max_length=36)
    sort_order: int
    room: str = Field(max_length=80)
    variant: str = Field(max_length=64)
    material_key: str | None = Field(default=None, max_length=64)
    layer: str = Field(max_length=16)
    parent_line_id: str | None = None

    #: Null only for a room-sourced flooring line -- see `direct_area_sqft`.
    est_width_tmm: int | None = Field(default=None, ge=0)
    est_height_tmm: int | None = Field(default=None, ge=0)
    final_width_tmm: int | None = Field(default=None, ge=0)
    final_height_tmm: int | None = Field(default=None, ge=0)
    #: Exact rational as a string, e.g. "700/3". Copied from the quote line
    #: this order line was confirmed from. Never fed into final pricing,
    #: which always needs a real tape measurement.
    direct_area_sqft: str | None = None
    is_site_measured: bool = False
    quantity: int = Field(default=1, ge=1)

    category_lock_id: str | None = None
    applied_rule_id: str = Field(max_length=64)
    applied_band_label: str | None = Field(default=None, max_length=64)
    applied_rate_card_version: int
    applied_discount_pct: str = "0"

    standard_rate_sen: int = Field(ge=0)
    rate_sen: int = Field(ge=0)
    billed_qty: str = Field(max_length=32)
    billed_unit: str = Field(max_length=16)
    line_total_sen: int = Field(ge=0)

    material_deferred: bool = False
    is_overridden: bool = False

    #: Where the estimate dimensions actually came from. SPEC.md Phase 8.
    #: Never ``site_measurement`` at push time -- a line only earns that
    #: through the dedicated measurement endpoint, after a real site visit,
    #: never by a device simply claiming it at order confirmation. Absent
    #: means ``manual``, true of every order ever pushed before this field
    #: existed.
    measurement_source: str = Field(
        default="manual", pattern="^(manual|project_library)$"
    )
    source_project_id: str | None = Field(default=None, max_length=36)
    source_unit_type_id: str | None = Field(default=None, max_length=36)
    source_version: int | None = Field(default=None, ge=1)


class OrderEventIn(BaseModel):
    """One entry of the append-only history. §6.3."""

    id: str = Field(min_length=36, max_length=36)
    event: str = Field(max_length=32)
    note: str | None = None
    at: datetime


class PriceOverrideIn(BaseModel):
    """One audit row. §6.5.

    ``reason`` and ``admin_user_id`` are both required and the reason has a
    floor, because a row that cannot say who or why is not an audit trail --
    and this table is the only actual control on overriding.
    """

    id: str = Field(min_length=36, max_length=36)
    order_line_id: str = Field(min_length=36, max_length=36)
    before_sen: int
    after_sen: int = Field(ge=0)
    reason: str = Field(min_length=MIN_REASON_LENGTH)
    admin_user_id: str = Field(min_length=1, max_length=36)
    device_id: str | None = None
    at: datetime


class OrderIn(BaseModel):
    """A confirmed order pushed up from a device. §6.3.

    No ``order_no``: like a receipt number it is issued by the server, and a
    device that sent one would be inventing something that goes on a document
    the customer takes away.
    """

    id: str = Field(min_length=36, max_length=36)
    quote_id: str = Field(min_length=36, max_length=36)
    channel: str = Field(pattern="^(showroom|home_visit|fair|referral|phone)$")
    pinned_rate_card_version: int

    customer_name: str | None = Field(default=None, max_length=120)
    customer_phone: str | None = Field(default=None, max_length=40)
    delivery_zone_id: str | None = Field(default=None, max_length=64)
    delivery_charge_sen: int = Field(default=0, ge=0)

    status: str = "confirmed"
    estimate_total_sen: int = Field(ge=0)
    deposit_paid_sen: int = Field(default=0, ge=0)
    has_unmeasured_lines: bool = True

    confirmed_at: datetime
    device_id: str | None = None

    lines: list[OrderLineIn] = []
    events: list[OrderEventIn] = []
    overrides: list[PriceOverrideIn] = []


class OrderResult(BaseModel):
    order_id: str
    #: True when this exact order had already been accepted. A retry is a
    #: success -- the device cannot know whether the first attempt landed, and
    #: two orders for one deposit is the failure this prevents.
    duplicate: bool
    #: The number the server issued, first time and every time after. A retry
    #: gets the **same** one back, so a reprinted document matches the first.
    order_no: str
    #: Set when the device pushed a status the server would not have allowed
    #: from the one it already holds. The order is still accepted -- the money
    #: is taken and refusing it would lose the sale -- but the status stays
    #: where the server had it and this says why.
    status_refused_because: str | None = None
    #: Overrides the server would not have allowed, by id. Accepted rows are
    #: stored; refused ones are not, and the line keeps the total it came with.
    overrides_refused: dict[str, str] = {}


class StatusChangeIn(BaseModel):
    """One step along the pipeline, pushed up after the device took it. §6.3.

    Carries the device's own ``event_id``: an order walks the pipeline many
    times, so the thing that must not be applied twice is one particular move,
    not the order.
    """

    order_id: str = Field(min_length=36, max_length=36)
    #: The append-only history row this move writes. Idempotency hangs on it.
    event_id: str = Field(min_length=36, max_length=36)
    to: str = Field(max_length=24)
    #: Required only when cancelling, and measured after trimming.
    reason: str | None = None
    at: datetime


class StatusChangeResult(BaseModel):
    order_id: str
    #: True when this exact move had already been applied. A retry is a success.
    duplicate: bool
    #: Where the order actually is now — which is where it was, if refused.
    status: str
    #: Why the server would not make the move, null when it did. Reported
    #: rather than raised: the device is offline-first and may be hours ahead,
    #: and it needs to know which move was rejected, not lose the batch.
    refused_because: str | None = None


class BuyerDetailsIn(BaseModel):
    """What was captured about the buyer, pushed up after the device took it.

    SPEC.md §10.3. Its own push rather than a field on the order, because an
    order is pushed **once at confirmation** and these are captured after
    measurement -- by which point that payload has long been sent.

    Every field is optional and **absent means "leave what is there"**. Two
    people can capture for one order: the measurer takes the TIN at the house,
    the office adds the address later. A payload that blanked what it did not
    carry would lose whichever was written first, and both are things somebody
    actually collected.

    To CLEAR a field, send it as an empty string. The server trims, so ``""``
    and ``"  "`` both mean "there is nothing here" -- which is what a legal
    requirement needs a blank to mean.
    """

    order_id: str = Field(min_length=36, max_length=36)
    #: When the device recorded them. The only ordering signal available when
    #: several handsets can capture offline for one order.
    captured_at: datetime

    #: The buyer's legal name. On the order already, and updated here too: an
    #: e-invoice needs the name on the IC, and a fair may have written down
    #: "Ah Lian's mother".
    name: str | None = None
    tin: str | None = None
    #: ``nric``, ``brn``, ``passport`` or ``army``.
    id_type: str | None = Field(default=None, max_length=16)
    id_number: str | None = None
    address_line1: str | None = None
    address_line2: str | None = None
    city: str | None = None
    state: str | None = None
    postcode: str | None = None
    msic_code: str | None = None
    einvoice_requested: bool | None = None


class BuyerDetailsResult(BaseModel):
    order_id: str
    #: True when what the server holds is now complete enough to invoice from
    #: -- the same rule the device shows, so the two cannot disagree about
    #: whether somebody still has to be telephoned.
    complete: bool
    #: What is still outstanding, in the rule's own order. Empty when complete.
    missing: list[str] = []
    #: Set when nothing was written. ``unknown_order`` if the order push has
    #: not landed; ``stale`` if a newer capture is already stored.
    refused_because: str | None = None


class MeasurementIn(BaseModel):
    """A site measurement pushed up after the device took it.

    SPEC.md §11 Phase 6. Its own push, for the same reason buyer details get
    one: an order is pushed **once at confirmation**, before the site visit
    happens. Staled on the line's own ``measured_at`` rather than the order's
    -- each line is measured independently, sometimes by different people on
    different visits, so a per-order timestamp would let a late line refuse a
    push that has nothing to do with it.
    """

    order_id: str = Field(min_length=36, max_length=36)
    line_id: str = Field(min_length=36, max_length=36)
    #: When the tape was read. The only ordering signal available when a line
    #: can be remeasured, or two handsets race on the same order offline.
    measured_at: datetime

    final_width_tmm: int | None = Field(default=None, ge=0)
    final_height_tmm: int | None = Field(default=None, ge=0)
    #: Absent means "leave it" -- a null measurer choice must never clear a
    #: material already chosen, the same rule as buyer details.
    material_key: str | None = None

    #: What the device's own repricing came to for this one line, so the
    #: server can compare and log a disagreement (hard rule 4) rather than
    #: silently trust either number. Null when the device's own reprice
    #: refused this line.
    device_final_total_sen: int | None = None


class MeasurementResult(BaseModel):
    order_id: str
    line_id: str
    is_site_measured: bool
    #: This order's total once every line has priced, null otherwise.
    final_total_sen: int | None = None
    has_unmeasured_lines: bool = True
    #: ``unknown_order``, ``unknown_line`` or ``stale``. Null when applied.
    refused_because: str | None = None


class CategoryLockIn(BaseModel):
    """A hold opened on a handset. §6.1.

    The device decides whether one may exist -- ``open_category_lock`` refuses
    outside a fair and below the minimum -- and the server re-checks nothing
    about that here, because the deposit has already been taken and refusing
    the hold would leave the customer having paid for nothing.
    """

    id: str = Field(min_length=36, max_length=36)
    #: A normalised phone, or `quote:<id>`. See app.pricing.customer_key.
    customer_key: str = Field(min_length=1, max_length=64)
    category: str = Field(pattern="^(curtain|flooring|wallpaper)$")
    deposit_payment_id: str | None = None

    held_rate_card_version: int
    #: An exact rational as a string -- "0", "1/10". Never a float.
    held_discount_pct: str = "0"
    held_until: datetime
    # `superseded` is accepted although only the server produces it: a handset
    # that pulled one down and pushed it back should not be refused.
    status: str = Field(
        default="active",
        pattern="^(active|expired|cancelled|refunded|superseded)$",
    )

    opened_at: datetime
    device_id: str | None = None


class CategoryLockOut(BaseModel):
    """A hold as a handset reads it back."""

    id: str
    customer_key: str
    category: str
    held_rate_card_version: int
    held_discount_pct: str
    held_until: datetime
    status: str


class LocksOut(BaseModel):
    """Every hold a customer still has.

    An object rather than a bare array: a top-level list has nowhere to put the
    next thing this endpoint needs to say, and every client would have to be
    changed on the day it does.
    """

    locks: list[CategoryLockOut] = []


class LockPushResult(BaseModel):
    lock_id: str
    #: True when this hold had already been accepted. A retry is a success --
    #: the RM300 was taken once and this is the same hold it bought.
    duplicate: bool
    #: Set when the server already holds a *different* active lock for this
    #: customer and category. The push is still accepted and stored as
    #: superseded rather than dropped: two handsets each taking a deposit for
    #: one category is a real thing that happens, and the money is real either
    #: way. It needs a human, not a silent discard.
    conflicts_with: str | None = None


class DepositPromptIn(BaseModel):
    """Whichever button was pressed when the RM300 was asked for. §6.2."""

    id: str = Field(min_length=36, max_length=36)
    quote_id: str = Field(min_length=36, max_length=36)
    category: str = Field(pattern="^(curtain|flooring|wallpaper)$")
    choice: str = Field(pattern="^(collected|declined|lines_removed|dismissed)$")
    category_subtotal_sen: int = Field(default=0, ge=0)
    at: datetime
    device_id: str | None = None


class DepositPromptResult(BaseModel):
    prompt_id: str
    duplicate: bool


class OrderSummary(BaseModel):
    """One card on the order board. §11 Phase 5.

    Deliberately not the whole order. The board shows 500 of these and sending
    every line with each would make the one screen the office lives in slow
    enough that people stop opening it.
    """

    id: str
    order_no: str | None
    status: str
    channel: str
    customer_name: str | None
    customer_phone: str | None
    estimate_total_sen: int
    deposit_paid_sen: int
    has_unmeasured_lines: bool
    confirmed_at: datetime
    line_count: int

    #: The earliest date any hold on this order runs out, or null when none
    #: does. The board sorts by it ascending and colours by how close it is:
    #: §11 Phase 5 wants amber at 60 days and red at 30, because a hold that
    #: expires unused is a customer who paid RM300 and got nothing.
    held_until: datetime | None = None


class OrdersOut(BaseModel):
    """A page of the order board.

    An object rather than a bare array so the total can travel with it -- a
    board that cannot say "showing 50 of 512" leaves somebody guessing whether
    the filter worked.
    """

    orders: list[OrderSummary] = []
    #: How many match the filter, not how many are on this page.
    total: int = 0


class OrderLineOut(BaseModel):
    id: str
    sort_order: int
    room: str
    variant: str
    material_key: str | None
    layer: str
    #: Null only for a room-sourced flooring line -- see `direct_area_sqft`.
    est_width_tmm: int | None
    est_height_tmm: int | None
    final_width_tmm: int | None
    final_height_tmm: int | None
    #: Exact rational as a string, e.g. "700/3". SPEC.md's property library.
    direct_area_sqft: str | None
    is_site_measured: bool
    quantity: int
    applied_rule_id: str
    applied_band_label: str | None
    applied_rate_card_version: int
    applied_discount_pct: str
    standard_rate_sen: int
    rate_sen: int
    billed_qty: str
    billed_unit: str
    line_total_sen: int
    material_deferred: bool
    is_overridden: bool


class OrderEventOut(BaseModel):
    id: str
    event: str
    note: str | None
    by_user_id: str | None
    at: datetime


class PriceOverrideOut(BaseModel):
    id: str
    order_line_id: str
    order_id: str
    before_sen: int
    after_sen: int
    reason: str
    admin_user_id: str
    at: datetime


class BuyerOut(BaseModel):
    """What is on file about the buyer, for the office. §10.3.

    What the office reads before it can tell whether an order is exportable at
    all. It writes back through the same ``POST /api/orders/buyer`` a handset
    pushes to -- one write path and one merge rule, so a desk and a handset
    cannot end up with different ideas about a field neither of them touched.

    ``complete`` and ``missing`` come from the same rule the handset shows, so
    the two cannot disagree about who still has to be chased.

    The identifier is deliberately **not** masked. This screen exists so the
    person doing the export can check the number against what the accounts
    system rejected, and a masked value would send them to the handset for it.
    """

    name: str | None = None
    tin: str | None = None
    id_type: str | None = None
    id_number: str | None = None
    address_line1: str | None = None
    address_line2: str | None = None
    city: str | None = None
    state: str | None = None
    postcode: str | None = None
    msic_code: str | None = None
    einvoice_requested: bool = False
    #: When a handset last captured. Null when nobody ever has, which reads
    #: differently from "captured and empty" and has to.
    captured_at: datetime | None = None

    complete: bool = False
    missing: list[str] = []


class OrderDetailOut(BaseModel):
    """One order, with everything needed to answer a question about it.

    The lines, the history and the overrides together: somebody looking at an
    order is almost always answering "why is this number what it is", and three
    round trips to answer that is three chances to give up.
    """

    order: OrderSummary
    lines: list[OrderLineOut] = []
    events: list[OrderEventOut] = []
    overrides: list[PriceOverrideOut] = []
    #: What is on file about the buyer, and what is still missing. The office
    #: runs the export, so it has to be able to see the gap without opening
    #: somebody's handset.
    buyer: BuyerOut | None = None


class OverridesOut(BaseModel):
    """The "overrides this week" screen. §6.5."""

    overrides: list[PriceOverrideOut] = []


class DepositPromptOut(BaseModel):
    id: str
    quote_id: str
    category: str
    choice: str
    category_subtotal_sen: int
    at: datetime


class DepositPromptsOut(BaseModel):
    """The declined-deposit report. §6.2."""

    prompts: list[DepositPromptOut] = []


class RateChangeOut(BaseModel):
    """One rule whose price would move."""

    rule_id: str
    label: str
    old_rate_sen: int | None
    new_rate_sen: int | None
    old_mvp_rate_sen: int | None
    new_mvp_rate_sen: int | None
    #: None for an added or removed rule -- "moved by RM46" is a sentence about
    #: a rule that existed before and still does.
    delta_sen: int | None


class CardDiffOut(BaseModel):
    """Everything a publish would do, before it does any of it. §11 Phase 5."""

    changed: list[RateChangeOut] = []
    added: list[RateChangeOut] = []
    #: A product that stops being quotable is at least as big a change as one
    #: that gets dearer, and it is the one nobody would notice.
    removed: list[RateChangeOut] = []
    #: Counted, not listed. A preview is only readable if it shows what moves.
    unchanged: int = 0
    #: True when publishing would create a version nobody can tell apart from
    #: the live one.
    is_empty: bool = True
    #: What the changed rules move by, added up. Forty rows each a ringgit
    #: dearer is a price rise nobody described that way.
    total_delta_sen: int = 0


class PreviewIn(BaseModel):
    """A card an admin is about to publish, and has not yet."""

    list_id: str = Field(pattern="^(fair|standard)$")
    payload: dict
    #: Which language to name the products in. The ids are stable; the labels
    #: are what an admin reads.
    language: str = Field(default="zh", pattern="^(zh|en|ms)$")


class PersonOut(BaseModel):
    """Somebody who uses the system.

    No PIN and no hash. Nothing that could be replayed leaves the server, and a
    hash is still something to attack offline.
    """

    id: str
    name: str
    phone: str | None
    email: str | None
    role: str
    language: str
    is_active: bool
    deactivated_at: datetime | None


class PeopleOut(BaseModel):
    #: Leavers included. A list that hides them cannot answer "who used to have
    #: access", which is the question somebody asks after something goes
    #: missing.
    people: list[PersonOut] = []


class AddPersonIn(BaseModel):
    """A new user, created by an admin who is already signed in.

    The first admin still needs shell access -- there is no register endpoint
    and no bootstrap password in the image. This only saves an admin from a
    terminal for the second person onwards, which lowers no bar and raises a
    real one: the alternative is one shared login reaching every handset.
    """

    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(min_length=3, max_length=40)
    #: Never returned, never logged. Refused if weak, before anything is
    #: written.
    pin: str = Field(min_length=1, max_length=12)
    role: str = Field(default="parttime", pattern="^(parttime|staff|admin)$")
    email: str | None = Field(default=None, max_length=120)
    language: str = Field(default="zh", pattern="^(zh|en|ms)$")


class SetPinIn(BaseModel):
    pin: str = Field(min_length=1, max_length=12)


class DeactivateOut(BaseModel):
    person: PersonOut
    #: How many live handsets that just signed out. Worth reporting: somebody
    #: deactivating a leaver wants to know the phone in their pocket stopped.
    sessions_revoked: int


class MeasurementJob(BaseModel):
    """One order waiting for a site visit. §11 Phase 5.

    Carries the counts a measurer needs before setting off -- how many windows,
    how many still have no tape taken to them, and how many materials are still
    to be chosen (§13 B7) -- and none of the money that would let somebody
    reprice from this screen. Repricing happens in Phase 6, at the held version.
    """

    order_id: str
    order_no: str | None
    status: str
    channel: str
    line_count: int
    #: Lines with no final dimensions yet. The size of the visit.
    unmeasured_line_count: int
    #: Lines quoted at the dearest option in their group with nothing chosen
    #: yet (§13 B7). Every one is a decision somebody has to make on site.
    material_pending_count: int
    estimate_total_sen: int
    confirmed_at: datetime
    #: When somebody booked the visit, or null while it is still unbooked.
    #: Read from the append-only history, never from a column: `orders` has no
    #: booking date and inventing one would mean writing a second truth.
    booked_at: datetime | None = None
    #: Whole days since the deposit was taken. Computed against an injected
    #: clock, so the number in a test is the number in the screen.
    waiting_days: int


class MeasurementGroup(BaseModel):
    """One trip. §11 Phase 5: *grouped by project so one trip covers several
    units*.

    There is no project library until Phase 8, and no address is captured
    anywhere, so the only grouping the data supports today is the customer --
    keyed on the normalised phone, exactly as a rate lock is (§13 B9). One
    customer with three units is one trip, which is the case that exists now.

    An order with no usable phone is its own group rather than being pooled
    with every other phone-less order. Pooling them would invent a trip that
    does not exist.
    """

    key: str
    customer_name: str | None
    customer_phone: str | None
    #: False when this group is one order that had no phone to group on.
    grouped_by_phone: bool
    jobs: list[MeasurementJob] = []
    #: The oldest deposit in the group. The queue is ordered by this: the
    #: customer who has waited longest goes first.
    oldest_confirmed_at: datetime
    waiting_days: int
    #: How many of these already have a visit booked. A group where that is
    #: zero is the one nobody has called yet.
    booked_count: int


class MeasurementQueueOut(BaseModel):
    """Everything waiting for a site visit, grouped into trips."""

    groups: list[MeasurementGroup] = []
    #: Orders, not groups. "12 jobs across 9 trips" is the sentence the office
    #: actually says.
    total_orders: int = 0


class SalespersonVariance(BaseModel):
    """One salesperson's estimate against the tape. §11 Phase 5, §6.3.

    §6.3: *the variance report by salesperson tells the boss who is guessing
    badly and needs retraining.* That only works if the systematic bias is
    subtracted first -- a quotation rounds every quantity **up** and the final
    bill uses the exact tape, so every honest estimate comes in high. What
    identifies a bad guesser is being much further out than everybody else, not
    being out at all.
    """

    user_id: str | None
    name: str | None
    #: Orders that have been finally priced. Zero until Phase 6 exists.
    orders_priced: int
    #: Confirmed and not yet measured. Named so an empty report explains
    #: itself rather than reading as "nobody sold anything".
    orders_awaiting_final: int
    estimate_total_sen: int
    final_total_sen: int
    #: `final - estimate`. Negative is the expected direction.
    variance_sen: int
    #: Orders where the final came out **above** the estimate. §8.5 says that
    #: cannot happen: *after site measurement the price will be the same or
    #: lower, never higher.* Any number here but zero is a broken promise, not
    #: a statistic, so it is counted separately and never averaged away.
    orders_over_estimate: int


class VarianceReport(BaseModel):
    rows: list[SalespersonVariance] = []
    #: True while nothing has been finally priced anywhere. The screen says so
    #: rather than showing an empty table that looks like a failed query.
    nothing_priced_yet: bool = True


class FairPerformance(BaseModel):
    """What one fair did. §11 Phase 5.

    Keyed on the promo code of the card an order pinned, which is what
    actually identifies a fair -- `channel = 'fair'` says an order came from
    one, and the pinned version says which.
    """

    promo_code: str | None
    valid_from: str | None
    valid_to: str | None
    orders: int
    estimate_total_sen: int
    deposits_taken_sen: int
    #: RM300s that opened a twelve-month hold at this fair. §6.1.
    locks_opened: int
    #: Deliberately no average order value. An average of integer sen needs a
    #: rounding rule, and there is no reason to invent one here when the count
    #: and the total are both on screen.


class FairReport(BaseModel):
    fairs: list[FairPerformance] = []


class OutstandingBalance(BaseModel):
    """One order with money still to come. §11 Phase 5.

    **Nothing here is called overdue.** The system does not know when a
    balance falls due -- there is no invoice date and no terms -- so what is
    reported is how long it has been since the deposit, and the reader draws
    the conclusion. §13 C11.
    """

    order_id: str
    order_no: str | None
    customer_name: str | None
    customer_phone: str | None
    status: str
    confirmed_at: datetime
    days_since_deposit: int
    total_sen: int
    deposit_paid_sen: int
    balance_sen: int
    #: True while the total is still the quotation. §8.5: a quotation is a
    #: reference price and the final will be the same or **lower**, so this
    #: balance is an upper bound and must not be read as a debt.
    is_estimate: bool


class AgeingBucket(BaseModel):
    """Days since the deposit, not days overdue. §13 C11.

    The **range**, not a label. It used to carry ``"0-30 days"`` and the
    dashboard printed it -- which made this endpoint the place a piece of
    English lived, on a screen that now speaks Chinese and Malay as well
    (§13 C9). The reader's own words are the reader's client's business; what
    the server knows is the window.

    Half-open, ``[days_from, days_to)``, so one order lands in exactly one
    bucket rather than in two or in neither. ``days_to`` is null on the last.
    """

    days_from: int
    days_to: int | None = None
    orders: int
    balance_sen: int


class BalancesReport(BaseModel):
    balances: list[OutstandingBalance] = []
    buckets: list[AgeingBucket] = []
    total_balance_sen: int = 0
    #: How much of the total is still an estimate rather than a final price.
    #: A report that mixed the two without saying so would overstate what is
    #: collectable.
    estimated_balance_sen: int = 0


# --- Property / Project / Unit Library. SPEC.md Phase 8. ---------------


class OpeningIn(BaseModel):
    label: str = Field(min_length=1, max_length=80)
    room: str = Field(min_length=1, max_length=80)
    floor: int | None = None
    nominal_w_tmm: int = Field(gt=0)
    nominal_h_tmm: int = Field(gt=0)
    sort_order: int = 0


class OpeningOut(BaseModel):
    id: str
    label: str
    room: str
    floor: int | None
    nominal_w_tmm: int
    nominal_h_tmm: int
    sort_order: int


class RoomIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    floor: int | None = None
    nominal_area_mm2: int = Field(gt=0)
    skirting_run_tmm: int | None = Field(default=None, ge=0)


class RoomOut(BaseModel):
    id: str
    name: str
    floor: int | None
    nominal_area_mm2: int
    skirting_run_tmm: int | None


class FloorPlanIn(BaseModel):
    file_ref: str = Field(min_length=1, max_length=300)
    #: "12/1" style rational string. Never a float -- CLAUDE.md's arithmetic
    #: invariant carves out no exception for a calibration aid.
    scale_tmm_per_px: str | None = None


class FloorPlanOut(BaseModel):
    id: str
    file_ref: str
    #: Null means metadata exists (from `FloorPlanIn` at creation) but no
    #: image has actually been uploaded yet -- `content_type is not None` is
    #: what a client checks before offering to show or calibrate the image.
    content_type: str | None
    scale_tmm_per_px: str | None
    uploaded_by_user_id: str | None
    uploaded_at: datetime


class ProjectIn(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    developer: str | None = Field(default=None, max_length=160)
    area: str | None = Field(default=None, max_length=120)


class ProjectOut(BaseModel):
    id: str
    name: str
    developer: str | None
    area: str | None
    created_at: datetime


class ProjectsOut(BaseModel):
    projects: list[ProjectOut] = []


class UnitTypeCreateIn(BaseModel):
    project_id: str = Field(min_length=36, max_length=36)
    name: str = Field(min_length=1, max_length=120)
    floor_count: int | None = Field(default=None, ge=1)
    variant_of: str | None = Field(default=None, min_length=36, max_length=36)
    openings: list[OpeningIn] = []
    rooms: list[RoomIn] = []
    floor_plan: FloorPlanIn | None = None
    #: True for a part-timer's one-shot submission: straight to
    #: `pending_review`, skipping `draft`. False (the default) is an admin's
    #: own upload, which starts as `draft` until they choose to approve it.
    submit: bool = False


class UnitTypeOut(BaseModel):
    id: str
    project_id: str
    #: Denormalised onto this row because the one screen that reads a list of
    #: these -- the admin review queue -- has to say "ABC Development, Type
    #: B" without a second round trip per row.
    project_name: str
    name: str
    floor_count: int | None
    variant_of: str | None
    status: str
    created_by_user_id: str | None
    created_at: datetime
    updated_at: datetime


class UnitTypeVersionOut(BaseModel):
    id: str
    version: int
    approved_by_user_id: str | None
    approved_at: datetime | None
    rejected_by_user_id: str | None
    rejected_at: datetime | None
    rejection_reason: str | None
    note: str | None
    openings: list[OpeningOut] = []
    rooms: list[RoomOut] = []
    floor_plan: FloorPlanOut | None = None


class UnitTypeDetailOut(BaseModel):
    unit_type: UnitTypeOut
    versions: list[UnitTypeVersionOut] = []


class UnitTypeWithVersionsOut(UnitTypeOut):
    """A row of the list endpoint, with every version's content attached.

    The only screen that lists these today is the admin review queue, and it
    has to show what was actually submitted, not just a name -- so the list
    carries the same content `UnitTypeDetailOut` does, flattened onto one
    object per row instead of nested one level deeper.
    """

    versions: list[UnitTypeVersionOut] = []


class UnitTypesOut(BaseModel):
    unit_types: list[UnitTypeWithVersionsOut] = []


class RejectUnitTypeIn(BaseModel):
    reason: str = Field(min_length=1, max_length=2000)


class NewVersionIn(BaseModel):
    """A correction. §7's versioning rule: never an edit, always a new row."""

    openings: list[OpeningIn] = []
    rooms: list[RoomIn] = []
    floor_plan: FloorPlanIn | None = None
    note: str | None = Field(default=None, max_length=2000)


class CalibrateFloorPlanIn(BaseModel):
    """Two tapped points, reduced to one integer. SPEC.md Phase 8.

    Not two pairs of coordinates: the Euclidean distance between two
    arbitrary points is irrational in general, and nothing about this
    endpoint should have to pretend otherwise. Whatever rounding a diagonal
    tap needs happens in the calibration UI; this is what is left once that
    is done -- a plain pixel count, so the server's own arithmetic
    (`real_distance_tmm / pixel_distance`) stays exactly rational.
    """

    pixel_distance: int = Field(gt=0)
    real_distance_tmm: int = Field(gt=0)


class RecognizeIn(BaseModel):
    """A floor-plan image, sent for a proposal only. SPEC.md Phase 8, "Future:
    assisted digitisation". Stateless -- there is no floor plan id, because
    this may be called before one exists (a part-timer's photo, not yet
    queued) as well as after (the dashboard re-sending a blob it already
    fetched).
    """

    content_type: str = Field(min_length=1, max_length=100)
    image_base64: str = Field(min_length=1)


class ProposedOpeningOut(BaseModel):
    label: str
    room: str
    nominal_w_tmm: int
    nominal_h_tmm: int
    confidence: float


class ProposedRoomOut(BaseModel):
    name: str
    nominal_area_mm2: int
    confidence: float


class ExtractionOut(BaseModel):
    """A proposal, never a write. Nothing in this response can become an
    `Opening` or a `Room` except by a person copying it into the submission
    form -- the same two-step gate that already keeps a part-timer's own
    upload out of the library until an admin approves it.
    """

    configured: bool
    provider: str
    note: str = ""
    openings: list[ProposedOpeningOut] = []
    rooms: list[ProposedRoomOut] = []


class FloorPlanSubmissionIn(BaseModel):
    """The image half of an offline unit-type submission. Travels as base64
    inside the same JSON payload as the rest of the submission, unlike the
    admin's own multipart upload route -- the whole thing is one outbox row,
    frozen at enqueue time, so a flaky fair connection has one request to
    get through rather than two.
    """

    filename: str = Field(min_length=1, max_length=300)
    content_type: str = Field(min_length=1, max_length=100)
    image_base64: str = Field(min_length=1)
    #: Both present or both absent -- enforced in the service layer, not
    #: here, so the one message names both fields together.
    pixel_distance: int | None = Field(default=None, gt=0)
    real_distance_tmm: int | None = Field(default=None, gt=0)


class UnitTypeSubmissionIn(BaseModel):
    """A part-timer's one-shot offline submission. SPEC.md Phase 8.

    Carries its own `id`, unlike `UnitTypeCreateIn` -- the admin/dashboard
    route generates one server-side because it is always called with a
    connection in hand; this is the offline sibling, pushed through the
    outbox like an order or a payment, and the device must know its id
    before a connection exists to ask the server for one.
    """

    id: str = Field(min_length=36, max_length=36)
    project_id: str = Field(min_length=36, max_length=36)
    name: str = Field(min_length=1, max_length=120)
    floor_count: int | None = Field(default=None, ge=1)
    openings: list[OpeningIn] = []
    rooms: list[RoomIn] = []
    floor_plan: FloorPlanSubmissionIn | None = None


class UnitTypeSubmissionResult(BaseModel):
    unit_type_id: str
    #: True when the device's id was already known -- a retry the server had
    #: already applied, not a second submission. Mirrors `OrderResult`.
    duplicate: bool


# ---------------------------------------------------------------------------
# Inventory. SPEC.md Phase 9.
# ---------------------------------------------------------------------------


class MaterialIn(BaseModel):
    family: str = Field(min_length=1, max_length=32)
    #: The pricing engine's own `variant` keys this material can allocate
    #: against -- stable identifiers, never a display string (§14.6).
    variant_compat: list[str] = []
    code: str = Field(min_length=1, max_length=64)
    names: dict[str, str]
    uom: str = Field(min_length=1, max_length=16)
    #: Exact rational as a string, e.g. "18" -- billed-quantity units one
    #: stock unit covers. Absent means no exact conversion is known yet
    #: (§13 F3): allocation for this material stays manual.
    coverage_per_unit: str | None = None
    reorder_level: str | None = None


class MaterialOut(BaseModel):
    id: str
    family: str
    variant_compat: list[str]
    code: str
    names: dict[str, str]
    uom: str
    coverage_per_unit: str | None
    reorder_level: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime


class MaterialsOut(BaseModel):
    materials: list[MaterialOut] = []


class ReceiveStockIn(BaseModel):
    material_id: str = Field(min_length=36, max_length=36)
    lot_ref: str = Field(min_length=1, max_length=80)
    qty: str = Field(min_length=1)
    cost_sen: int | None = Field(default=None, ge=0)
    location: str | None = Field(default=None, max_length=80)
    received_at: datetime | None = None
    note: str | None = Field(default=None, max_length=2000)


class StockLotOut(BaseModel):
    id: str
    material_id: str
    lot_ref: str
    qty_on_hand: str
    location: str | None
    received_at: datetime
    #: Admin-only route, so this travels -- see `StockLot`'s own docstring.
    cost_sen: int | None


class StockLotsOut(BaseModel):
    lots: list[StockLotOut] = []


class AdjustStockIn(BaseModel):
    lot_id: str = Field(min_length=36, max_length=36)
    #: Signed exact rational -- positive in, negative out.
    delta: str = Field(min_length=1)
    reason: str = Field(min_length=1, max_length=24)
    note: str | None = Field(default=None, max_length=2000)


class StockMovementOut(BaseModel):
    id: str
    material_id: str
    lot_id: str
    delta: str
    reason: str
    order_id: str | None
    by_user_id: str
    at: datetime
    note: str | None


class StockMovementsOut(BaseModel):
    movements: list[StockMovementOut] = []


class AllocationOut(BaseModel):
    id: str
    order_line_id: str
    order_id: str
    material_id: str
    lot_id: str | None
    qty: str
    status: str
    proposed_at: datetime
    decided_by_user_id: str | None
    decided_at: datetime | None
    decision_note: str | None
    allocated_at: datetime | None
    released_at: datetime | None


class AllocationsOut(BaseModel):
    allocations: list[AllocationOut] = []


class ManualAllocationIn(BaseModel):
    """An admin allocates directly, already decided -- for a material with
    no exact auto-proposal conversion (§13 F3), or a manual split across a
    second lot.
    """

    order_line_id: str = Field(min_length=1, max_length=36)
    order_id: str = Field(min_length=36, max_length=36)
    material_id: str = Field(min_length=36, max_length=36)
    lot_id: str = Field(min_length=36, max_length=36)
    qty: str = Field(min_length=1)


class ApproveAllocationIn(BaseModel):
    #: Overrides the auto-picked lot -- required when a proposal had none
    #: (§13 F3's "no single lot covers it" case), optional otherwise.
    lot_id: str | None = Field(default=None, min_length=36, max_length=36)


class RejectAllocationIn(BaseModel):
    reason: str = Field(min_length=1, max_length=2000)


class ReleaseAllocationIn(BaseModel):
    note: str | None = Field(default=None, max_length=2000)


class ReorderAlertOut(BaseModel):
    material: MaterialOut
    on_hand: str
    committed: str
    available: str
    reorder_level: str


class ReorderAlertsOut(BaseModel):
    alerts: list[ReorderAlertOut] = []

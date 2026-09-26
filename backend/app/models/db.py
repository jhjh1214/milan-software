"""Server-side tables. SQLAlchemy 2.0, typed, per CLAUDE.md.

Conventions from §7, all of them load-bearing:

- ``id`` is a **client-generated** UUID v4. Two part-timers offline at one fair
  must never collide, so the device makes the id and the server accepts it.
  That is also what makes the push idempotent: a retry carries the same id.
- Lengths end ``_tmm`` and are integers, in tenths of a millimetre.
- Money ends ``_sen`` and is an integer. No ``NUMERIC`` for currency, ever.
- Timestamps are ``timestamptz``, stored UTC, displayed Asia/Kuala_Lumpur.
- Ledgers are append-only. Corrections are new rows with a reason.
"""

from __future__ import annotations

from datetime import date, datetime

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

#: JSONB on Postgres, plain JSON elsewhere. The tests run on SQLite so the
#: ingest logic can be exercised without a container; production is Postgres
#: and gets the indexable type.
JsonColumn = JSON().with_variant(JSONB(), "postgresql")


class Base(DeclarativeBase):
    pass


class RateCardVersion(Base):
    """A published price list.

    Rows are **never updated in place and never deleted** (CLAUDE.md). A price
    change publishes a new version, so a quote that recorded version 1 can still
    be explained after version 2 exists.
    """

    __tablename__ = "rate_cards"

    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    #: `fair` or `standard`. Separate lineages, never interleaved.
    list_id: Mapped[str] = mapped_column(String(32))
    #: The whole card as published. Stored whole rather than shredded into rows
    #: because §9.1 replaces it wholesale on the device and never diffs it.
    payload: Mapped[dict] = mapped_column(JsonColumn)
    is_active: Mapped[bool] = mapped_column(Boolean, default=False)
    published_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    published_by: Mapped[str | None] = mapped_column(String(64), nullable=True)

    __table_args__ = (
        Index(
            "ix_rate_cards_active",
            "list_id",
            unique=True,
            # Only one active card per list. Declared for both dialects: on
            # SQLite a bare unique index would also forbid keeping the
            # superseded versions, which CLAUDE.md requires.
            postgresql_where=(is_active.is_(True)),
            sqlite_where=(is_active.is_(True)),
        ),
    )


class RateCardEdit(Base):
    """One product's price, changed directly and live -- never through the
    whole-card upload/preview/publish flow.

    **APPEND ONLY, and never deletable from the app.** The same control
    `PriceOverride` already is for an order line: a staff or admin PIN is a
    speed bump, and what actually stops abuse is that every move is
    recorded against a name, with a reason, and read back later. `reason`
    and `by_user_id` are both NOT NULL for exactly that reason.

    Still publishes a new `RateCardVersion` rather than editing a row in
    place -- a quote priced at the old rate, or a rate lock pinned to the
    old version, must stay explainable after this edit as much as after a
    whole-card publish. This table is the audit trail *for* that new
    version, not a replacement for versioning.
    """

    __tablename__ = "rate_card_edits"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    rule_id: Mapped[str] = mapped_column(String(64))
    #: `fair` or `standard`. Which lineage this edit published a new version of.
    list_id: Mapped[str] = mapped_column(String(32))

    before_rate_sen: Mapped[int] = mapped_column(BigInteger)
    after_rate_sen: Mapped[int] = mapped_column(BigInteger)
    before_mvp_rate_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    after_mvp_rate_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    #: The version this edit produced. Traceable back to `rate_cards.version`
    #: without a foreign key -- superseded rows are kept, never deleted, so
    #: the reference stays valid for good.
    resulting_version: Mapped[int] = mapped_column(Integer)

    reason: Mapped[str] = mapped_column(Text)
    by_user_id: Mapped[str] = mapped_column(String(36))
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (Index("ix_rate_card_edits_at", "at"),)


class FairDatesEdit(Base):
    """An admin changing when a fair runs -- the fair card's promo window.

    **APPEND ONLY, and never deletable from the app**, for the same reason as
    `RateCardEdit`: the dates decide which days a handset quotes fair prices
    and when every deposit from that fair stops holding its price (SPEC.md
    §6.1), so each move is recorded against a name with a reason.

    Like a price edit, it publishes a new `RateCardVersion` rather than
    editing the card in place; this row is the audit trail for that version.
    A hold already granted keeps the `held_until` it was given -- moving a
    fair's end afterwards does not reach back into it.
    """

    __tablename__ = "fair_dates_edits"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)

    #: Null when the card had no promo window before this edit.
    before_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    before_valid_from: Mapped[date | None] = mapped_column(Date, nullable=True)
    before_valid_to: Mapped[date | None] = mapped_column(Date, nullable=True)

    after_code: Mapped[str] = mapped_column(String(64))
    after_valid_from: Mapped[date] = mapped_column(Date)
    after_valid_to: Mapped[date] = mapped_column(Date)

    resulting_version: Mapped[int] = mapped_column(Integer)
    reason: Mapped[str] = mapped_column(Text)
    by_user_id: Mapped[str] = mapped_column(String(36))
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (Index("ix_fair_dates_edits_at", "at"),)


class User(Base):
    """A person. §7.

    ``pin_hash`` is **individual, never shared**. SPEC.md §6.5 is blunt about
    why: one shared admin password reaches every part-timer within a month, and
    then the audit log names nobody. The gate is not the control; the log is,
    and the log is worthless if it cannot name a person.
    """

    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    #: How someone identifies themselves at login. Unique where present.
    phone: Mapped[str | None] = mapped_column(String(40), nullable=True)
    email: Mapped[str | None] = mapped_column(String(120), nullable=True)
    #: admin | staff | parttime. §3: same wizard for all three, only rate
    #: visibility differs.
    role: Mapped[str] = mapped_column(String(16), default="parttime")
    pin_hash: Mapped[str | None] = mapped_column(Text, nullable=True)
    language: Mapped[str] = mapped_column(String(4), default="zh")
    #: Leavers are deactivated, never deleted -- their quotes and payments have
    #: to keep naming them.
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    deactivated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    __table_args__ = (Index("ix_users_phone", "phone", unique=True),)


class DeviceSession(Base):
    """One handset, logged in as one person.

    **No expiry.** SPEC.md §12: "Indefinite. No token expiry that locks a user
    out." A token that expires does so at the worst possible moment -- mid-fair,
    with no signal, holding a customer's deposit. Revocation is the control
    instead, and it is a server-side act on a named session.

    Only the token's SHA-256 is stored, so a leaked database dump does not hand
    over live sessions.
    """

    __tablename__ = "device_sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"))
    #: The device's own id, client-generated like every other id here.
    device_id: Mapped[str] = mapped_column(String(36))
    device_label: Mapped[str | None] = mapped_column(String(80), nullable=True)
    token_hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    last_seen_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_reason: Mapped[str | None] = mapped_column(Text, nullable=True)

    user: Mapped[User] = relationship()

    __table_args__ = (
        Index("ix_device_sessions_token", "token_hash", unique=True),
        Index("ix_device_sessions_user", "user_id"),
    )


class LoginAttempt(Base):
    """Every login try, successful or not. APPEND ONLY.

    Two jobs. It is the record of who signed in on which handset, and it is what
    the throttle counts: scrypt makes an offline attack expensive, but nothing
    in the hash slows down someone guessing a four-digit PIN over HTTP.

    Deliberately **not** a lockout. A locked account at a fair is a person who
    cannot take deposits, which costs more than the attack does.
    """

    __tablename__ = "login_attempts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    #: What was typed in the identifier box. Kept even when no such user
    #: exists -- that pattern is itself the signal.
    phone: Mapped[str] = mapped_column(String(40))
    user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    succeeded: Mapped[bool] = mapped_column(Boolean)
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (Index("ix_login_attempts_phone_at", "phone", "at"),)


class Quote(Base):
    """A quotation pushed up from a device."""

    __tablename__ = "quotes"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    rate_card_version: Mapped[int] = mapped_column(Integer)
    tier: Mapped[str] = mapped_column(String(16), default="standard")
    language: Mapped[str] = mapped_column(String(4), default="zh")

    customer_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    customer_phone: Mapped[str | None] = mapped_column(String(40), nullable=True)
    delivery_zone_id: Mapped[str | None] = mapped_column(String(64), nullable=True)

    #: What the device calculated. Kept beside the server's own figure so §9.4
    #: can compare them rather than overwrite one with the other.
    device_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    server_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    #: Taken from the session that pushed it, never from the request body: a
    #: device must not be able to claim it was someone else.
    taken_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id"), nullable=True
    )

    lines: Mapped[list[QuoteLine]] = relationship(
        back_populates="quote", cascade="all, delete-orphan"
    )

    __table_args__ = (Index("ix_quotes_received", "received_at"),)


class QuoteLine(Base):
    """One window.

    Stores what was **entered**, not what was computed, so the server can price
    it independently — which is the whole point of §9.4.
    """

    __tablename__ = "quote_lines"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    quote_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("quotes.id", ondelete="CASCADE")
    )
    sort_order: Mapped[int] = mapped_column(Integer)

    room: Mapped[str] = mapped_column(String(80))
    variant: Mapped[str] = mapped_column(String(64))
    material_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    layer: Mapped[str] = mapped_column(String(16))
    parent_line_id: Mapped[str | None] = mapped_column(String(36), nullable=True)

    #: Null only for a room-sourced flooring line -- see `direct_area_sqft`.
    #: A saved room's area does not reduce to one rectangle, so there is
    #: nothing honest to put here.
    width_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    height_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    raw_width: Mapped[str] = mapped_column(String(32))
    raw_height: Mapped[str] = mapped_column(String(32))
    quantity: Mapped[int] = mapped_column(Integer, default=1)

    #: Exact rational as a string, e.g. "700/3". SPEC.md's property
    #: library: a saved room's `nominal_area_mm2` is the one figure it
    #: actually stores, never a width and a length. Set only alongside
    #: `width_tmm=None`.
    direct_area_sqft: Mapped[str | None] = mapped_column(String(40), nullable=True)

    #: The device's figure, and the server's. §9.4: on a mismatch, accept the
    #: order and raise it for review. Never lose a sale over a rounding
    #: disagreement, and never silently accept the client's number either.
    device_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    server_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    quote: Mapped[Quote] = relationship(back_populates="lines")

    __table_args__ = (Index("ix_quote_lines_quote", "quote_id", "sort_order"),)


class Payment(Base):
    """Money taken on a device. §6.4.

    The system **records** payments; it does not process them. The card
    terminal stays where it is, so there is no PCI scope and no chargeback
    exposure here.

    APPEND ONLY. A refund is a new row, never an edit to the row it reverses.
    """

    __tablename__ = "payments"

    #: The device's own id. The push is idempotent on it, so a retry after a
    #: dropped connection cannot take the same RM300 twice.
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    quote_id: Mapped[str] = mapped_column(String(36))
    category_lock_id: Mapped[str | None] = mapped_column(String(36), nullable=True)

    kind: Mapped[str] = mapped_column(String(16))
    amount_sen: Mapped[int] = mapped_column(BigInteger)
    method: Mapped[str] = mapped_column(String(24))
    external_ref: Mapped[str | None] = mapped_column(String(80), nullable=True)

    #: **Issued here, never on a device.** It goes on a legal document, and two
    #: handsets offline at one fair would invent the same number.
    receipt_no: Mapped[str | None] = mapped_column(String(32), nullable=True)

    taken_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id"), nullable=True
    )
    taken_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    status: Mapped[str] = mapped_column(String(16), default="settled")

    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        Index("ix_payments_quote", "quote_id"),
        Index("ix_payments_taken", "taken_at"),
        # A receipt number identifies one payment or it identifies nothing.
        Index("ix_payments_receipt", "receipt_no", unique=True),
    )


class ReceiptCounter(Base):
    """The next receipt number in a period. §6.4, and CLAUDE.md on IDs.

    One row per ``YYYYMM``, incremented under a row lock, so two devices
    syncing at once cannot be handed the same number. The device never sees
    this table: it pushes a payment and is told what the number turned out to
    be.
    """

    __tablename__ = "receipt_counters"

    period: Mapped[str] = mapped_column(String(6), primary_key=True)
    next_value: Mapped[int] = mapped_column(Integer, default=1)


class PricingDiscrepancy(Base):
    """A line the server priced differently from the device.

    APPEND ONLY. §9.4: accept the order, store both numbers, raise it on an
    admin review screen. A mismatch means the two engines have drifted, and this
    table is how that is discovered before a customer notices.
    """

    __tablename__ = "pricing_discrepancies"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    quote_id: Mapped[str] = mapped_column(String(36))
    line_id: Mapped[str] = mapped_column(String(36))
    rate_card_version: Mapped[int] = mapped_column(Integer)
    device_total_sen: Mapped[int] = mapped_column(BigInteger)
    server_total_sen: Mapped[int] = mapped_column(BigInteger)
    detail: Mapped[str | None] = mapped_column(Text, nullable=True)
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    reviewed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    __table_args__ = (
        Index(
            "ix_discrepancies_unreviewed",
            "at",
            postgresql_where=(reviewed_at.is_(None)),
            sqlite_where=(reviewed_at.is_(None)),
        ),
    )


class IdempotencyRecord(Base):
    """Proof that a push has already been applied.

    §9.2: server endpoints are **idempotent on the client UUID**, and retry must
    be safe. A fair's connection drops mid-request constantly; the device cannot
    know whether the server got it, so it sends again. This table is what makes
    that harmless.
    """

    __tablename__ = "idempotency"

    #: The client's own id for the operation, not one the server invented.
    key: Mapped[str] = mapped_column(String(80), primary_key=True)
    entity_type: Mapped[str] = mapped_column(String(32))
    entity_id: Mapped[str] = mapped_column(String(36))
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    # Named explicitly: an anonymous constraint gets a dialect-invented name,
    # and a later migration that needs to drop it would have nothing to name.
    __table_args__ = (
        UniqueConstraint("entity_type", "entity_id", name="uq_idempotency_entity"),
    )


class Order(Base):
    """A confirmed sale pushed up from a device. §6.3.

    A deposit is what confirms it, so an order arriving here is money already
    taken. That shapes two things about this table.

    The ``id`` is the device's own UUID and the push is idempotent on it, so a
    fair's dropped connection cannot produce two orders for one deposit.

    The ``order_no`` is **issued here, never on a device** -- the same rule as a
    receipt number, for the same reason. ``{branch}-{yymm}-{seq}`` has no
    per-device component, so two part-timers offline at one fair would both mint
    the same one, and it goes on a document the customer takes away. The device
    shows "pending sync" until this comes back.

    The quote is referenced, never consumed. ``quote_id`` points back at the
    estimate the measurement team reads and the variance report compares
    against, and the lines here are **copies** -- editing an old quote must not
    change a confirmed order.
    """

    __tablename__ = "orders"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    quote_id: Mapped[str] = mapped_column(String(36))

    #: Null until issued. Never fabricated on a device.
    order_no: Mapped[str | None] = mapped_column(String(32), nullable=True)

    channel: Mapped[str] = mapped_column(String(16))
    pinned_rate_card_version: Mapped[int] = mapped_column(Integer)

    customer_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    customer_phone: Mapped[str | None] = mapped_column(String(40), nullable=True)
    delivery_zone_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    delivery_charge_sen: Mapped[int] = mapped_column(BigInteger, default=0)
    #: Free text, typed in by staff planning a day's visits -- not a real
    #: address record (no postcode, no geocoding). Just enough to open a free
    #: Google Maps search link before a visit. §13 C10's write-up.
    site_address_note: Mapped[str | None] = mapped_column(String(240), nullable=True)
    #: Where the visit is, for grouping a day's trips (§13 C10): a Malaysian
    #: postcode, five digits. Captured at the fair when the customer has it,
    #: filled in later when they do not -- never required to take a deposit.
    site_postcode: Mapped[str | None] = mapped_column(String(5), nullable=True)
    #: The first day the house can be measured -- keys handed over. Null means
    #: ready now, or not known; a future date keeps the order out of the
    #: "book this trip" list until it arrives.
    site_ready_from: Mapped[date | None] = mapped_column(Date, nullable=True)
    #: When the site details were last captured, by a handset or the office.
    #: The ordering signal that refuses a stale push, as `buyer_captured_at`
    #: is for buyer details -- the handset and the dashboard both write these.
    site_captured_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    status: Mapped[str] = mapped_column(String(24), default="confirmed")

    #: Both are kept. §6.3: the variance report by salesperson is what tells the
    #: boss who is guessing badly and needs retraining.
    estimate_total_sen: Mapped[int] = mapped_column(BigInteger)
    final_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    deposit_paid_sen: Mapped[int] = mapped_column(BigInteger, default=0)
    has_unmeasured_lines: Mapped[bool] = mapped_column(Boolean, default=True)

    # Buyer details, for the e-invoice SQL Account issues. §10.3.
    #
    # Nullable and null on most orders: a walk-in is General Public and needs
    # none of this. They become required when the total crosses RM10,000
    # (§10.2) or when the customer asks (§10.3), and **what counts as complete
    # is a rule** (`pricing/einvoice_threshold.py`) rather than a flag anybody
    # can tick.
    #
    # Here as well as on the device because the office does the export, and
    # details sitting on one handset are the same as no details as far as the
    # accounts system is concerned -- the identical failure the rate locks had
    # before migration 0005.
    #
    # On the order rather than on a customer record because there is no
    # customer table yet (§13 B9). When one arrives these move and the order
    # keeps a snapshot: what was true when the invoice was issued is not what
    # is true when somebody moves house.
    buyer_tin: Mapped[str | None] = mapped_column(String(32), nullable=True)
    #: `nric`, `brn`, `passport` or `army`. Stored with its number or not at
    #: all -- a number with no type cannot be filed.
    buyer_id_type: Mapped[str | None] = mapped_column(String(16), nullable=True)
    buyer_id_number: Mapped[str | None] = mapped_column(String(64), nullable=True)
    buyer_address_line1: Mapped[str | None] = mapped_column(String(160), nullable=True)
    buyer_address_line2: Mapped[str | None] = mapped_column(String(160), nullable=True)
    buyer_city: Mapped[str | None] = mapped_column(String(80), nullable=True)
    buyer_state: Mapped[str | None] = mapped_column(String(80), nullable=True)
    buyer_postcode: Mapped[str | None] = mapped_column(String(16), nullable=True)
    #: Business buyers only.
    buyer_msic_code: Mapped[str | None] = mapped_column(String(16), nullable=True)
    #: The customer asked for an e-invoice. §10.3: required at any value, so
    #: this is a reason to capture on its own rather than only a preference.
    einvoice_requested: Mapped[bool] = mapped_column(Boolean, default=False)
    #: When the device recorded them. Used to reject a stale push arriving
    #: after a newer one, which is the only ordering guarantee available when
    #: several handsets can capture for one order.
    buyer_captured_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    confirmed_by_user_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("users.id"), nullable=True
    )
    confirmed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    lines: Mapped[list[OrderLine]] = relationship(
        back_populates="order", cascade="all, delete-orphan"
    )

    __table_args__ = (
        Index("ix_orders_received", "received_at"),
        Index("ix_orders_status", "status"),
        Index("ix_orders_quote", "quote_id"),
        # An order number identifies one order or it identifies nothing.
        Index("ix_orders_order_no", "order_no", unique=True),
    )


class OrderLine(Base):
    """One line of a confirmed order. §6.3.

    A **copy** of the quote line, not a reference to it, carrying a snapshot of
    the rule, band, rate, card version and discount that priced it. A year later
    a customer asks why a curtain cost RM552, and the answer has to be available
    without reconstructing which card was in force that afternoon -- by then it
    may have been superseded twice.
    """

    __tablename__ = "order_lines"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("orders.id", ondelete="CASCADE")
    )
    #: The trail back to the estimate this was copied from.
    quote_line_id: Mapped[str] = mapped_column(String(36))
    sort_order: Mapped[int] = mapped_column(Integer)

    room: Mapped[str] = mapped_column(String(80))
    variant: Mapped[str] = mapped_column(String(64))
    material_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    layer: Mapped[str] = mapped_column(String(16))
    parent_line_id: Mapped[str | None] = mapped_column(String(36), nullable=True)

    #: Estimated at the fair, and kept for good. The final ones sit beside them
    #: rather than on top, so the variance report has both to compare.
    #: Null only for a room-sourced flooring line -- see `direct_area_sqft`.
    est_width_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    est_height_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    final_width_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    final_height_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)

    #: Exact rational as a string, e.g. "700/3". Copied from the quote line
    #: it was confirmed from -- kept for the same reason `est_width_tmm` is:
    #: a year later the estimate has to be explainable without reconstructing
    #: it. Never fed into final pricing, which always needs a real tape
    #: measurement (`final_width_tmm`/`final_height_tmm`).
    direct_area_sqft: Mapped[str | None] = mapped_column(String(40), nullable=True)
    is_site_measured: Mapped[bool] = mapped_column(Boolean, default=False)
    measured_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    measured_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    quantity: Mapped[int] = mapped_column(Integer, default=1)

    #: Which lock priced this line, null when none did. §6.1: applying a curtain
    #: lock to a flooring line is the expensive bug in this design.
    category_lock_id: Mapped[str | None] = mapped_column(String(36), nullable=True)

    applied_rule_id: Mapped[str] = mapped_column(String(64))
    applied_band_label: Mapped[str | None] = mapped_column(String(64), nullable=True)
    applied_rate_card_version: Mapped[int] = mapped_column(Integer)
    #: An exact rational written as a string -- "0", "1/10". Never a float: a
    #: percentage of a price is money.
    applied_discount_pct: Mapped[str] = mapped_column(String(24), default="0")

    standard_rate_sen: Mapped[int] = mapped_column(BigInteger)
    rate_sen: Mapped[int] = mapped_column(BigInteger)
    billed_qty: Mapped[str] = mapped_column(String(32))
    billed_unit: Mapped[str] = mapped_column(String(16))
    line_total_sen: Mapped[int] = mapped_column(BigInteger)

    #: Quoted at the dearest option in its group, pending a choice. §13 B7.
    material_deferred: Mapped[bool] = mapped_column(Boolean, default=False)
    #: Somebody moved this total by hand. Never cleared. §6.5.
    is_overridden: Mapped[bool] = mapped_column(Boolean, default=False)

    #: Where the dimensions on this line actually came from. SPEC.md Phase 8.
    #: An enum from the start rather than a boolean: adding a third source
    #: later to a boolean ``is_site_measured`` would be a migration across
    #: every order ever written, and Phase 8 is exactly that third source.
    #: A plan-sourced line is a better-informed estimate, never a measured
    #: one -- it still has to earn `is_site_measured=True` the same way any
    #: other line does, through a real site visit.
    measurement_source: Mapped[str] = mapped_column(String(16), default="manual")
    source_project_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    source_unit_type_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    source_version: Mapped[int | None] = mapped_column(Integer, nullable=True)

    order: Mapped[Order] = relationship(back_populates="lines")

    __table_args__ = (Index("ix_order_lines_order", "order_id", "sort_order"),)


class OrderEvent(Base):
    """One thing that happened to an order. §6.3.

    **APPEND ONLY.** This is the history somebody reads a year later to answer
    what happened to a job, so a correction is a new row rather than an edit to
    an old one.
    """

    __tablename__ = "order_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("orders.id", ondelete="CASCADE")
    )
    event: Mapped[str] = mapped_column(String(32))
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (Index("ix_order_events_order", "order_id", "at"),)


class PriceOverride(Base):
    """Every price an admin moved by hand. §6.5.

    **APPEND ONLY, and never deletable from the app.** This table *is* the
    control: an offline PIN is bypassable and one shared admin password reaches
    every part-timer within a month, so what actually stops abuse is that every
    move is recorded against a name and read once a week.

    Which is why ``reason`` and ``admin_user_id`` are both NOT NULL. A row that
    cannot say who or why is not an audit trail; it is a record that a number
    changed.
    """

    __tablename__ = "price_overrides"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_line_id: Mapped[str] = mapped_column(String(36))
    #: Denormalised off the line for the "overrides this week" screen, which
    #: groups by order. §6.5 puts the whole control on that screen being built.
    order_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("orders.id", ondelete="CASCADE")
    )

    before_sen: Mapped[int] = mapped_column(BigInteger)
    after_sen: Mapped[int] = mapped_column(BigInteger)
    reason: Mapped[str] = mapped_column(Text)
    admin_user_id: Mapped[str] = mapped_column(String(36))
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        Index("ix_price_overrides_at", "at"),
        Index("ix_price_overrides_order", "order_id"),
    )


class OrderCounter(Base):
    """The next order number in a period, per branch. §6.3.

    The same mechanism as ``ReceiptCounter`` and for the same reason: the number
    goes on a document the customer takes away, and ``{branch}-{yymm}-{seq}``
    has no per-device component to keep two offline handsets apart.
    """

    __tablename__ = "order_counters"

    #: ``{branch}:{YYYYMM}``. One counter per branch per month, so opening a
    #: second branch does not renumber the first.
    key: Mapped[str] = mapped_column(String(32), primary_key=True)
    next_value: Mapped[int] = mapped_column(Integer, default=1)


class CategoryLock(Base):
    """One RM300, holding one category's prices for twelve months. §6.1.

    Held on the server as well as on the device, because the device half only
    answers for the handset that took the deposit. Six phones work a fair; the
    customer deposits on phone 3 and walks into the showroom in March where
    phone 1 is used. Without this table that customer is quoted the standard
    rate -- more than the hold they paid for.

    ``customer_key`` is what ``app.pricing.customer_key`` produces: a
    normalised phone where there is one, and ``quote:<id>`` where there is not.
    §13 B9 is where the proper customer record gets decided; until then this is
    the durable thing a hold can hang on.

    Rows are never edited into existence. ``open_category_lock`` in
    ``app.pricing.rate_lock`` is the only thing that builds one, and it refuses
    outside a fair and below the minimum.
    """

    __tablename__ = "category_locks"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    customer_key: Mapped[str] = mapped_column(String(64))
    category: Mapped[str] = mapped_column(String(16))

    #: The payment that bought it, so a refund can find the lock it cancels.
    deposit_payment_id: Mapped[str | None] = mapped_column(String(36), nullable=True)

    #: Pinned **both**, at deposit time. Pinning only the version silently
    #: reprices this customer when the promo percentage moves.
    held_rate_card_version: Mapped[int] = mapped_column(Integer)
    #: An exact rational as a string -- "0", "1/10". Never a float: a
    #: percentage of a price is money.
    held_discount_pct: Mapped[str] = mapped_column(String(24), default="0")

    #: The last day the hold is good for, inclusive.
    held_until: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    status: Mapped[str] = mapped_column(String(16), default="active")

    opened_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        # The lookup every handset makes: whose locks are these.
        Index("ix_category_locks_customer", "customer_key", "status"),
        # §6.1: UNIQUE(customer_id, category) WHERE status = 'active'. Two
        # active holds on one category would make "which rate did the RM300
        # buy" a question with two answers.
        Index(
            "ix_category_locks_one_active",
            "customer_key",
            "category",
            unique=True,
            postgresql_where=(status == "active"),
            sqlite_where=(status == "active"),
        ),
    )


class DepositPrompt(Base):
    """Whichever button was pressed when the RM300 was asked for. §6.2.

    **APPEND ONLY.** The declined-deposit report is the point: it tells the
    boss what fairs are leaving on the table, and it only exists if a decline
    is recorded as carefully as a sale.

    ``dismissed`` is kept distinct from ``declined``. "They said no" and
    "nobody asked properly" are different problems, and only one of them is the
    customer's.
    """

    __tablename__ = "deposit_prompts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    quote_id: Mapped[str] = mapped_column(String(36))
    category: Mapped[str] = mapped_column(String(16))
    choice: Mapped[str] = mapped_column(String(16))

    #: What the quote was worth in this category when the question was asked,
    #: so the report can say what was left on the table rather than only how
    #: often somebody said no.
    category_subtotal_sen: Mapped[int] = mapped_column(BigInteger, default=0)

    by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    device_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        Index("ix_deposit_prompts_at", "at"),
        Index("ix_deposit_prompts_quote", "quote_id"),
    )


class Project(Base):
    """A development the company quotes repeatedly. SPEC.md Phase 8.

    *Reference property measurements are NOT site measurements.* This table
    and everything under it accelerate quoting; they never substitute for the
    site visit a real order still needs (§6.3's pipeline is unchanged).

    ``id`` is server-generated, like ``User.id`` -- created here at a desk
    with a connection, not client-side at a fair, so there is no offline
    collision to guard against.
    """

    __tablename__ = "projects"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    name: Mapped[str] = mapped_column(String(160))
    developer: Mapped[str | None] = mapped_column(String(160), nullable=True)
    #: Free text. What a salesperson types to find this again -- "entering the
    #: area or development name offers the unit types already digitised."
    area: Mapped[str | None] = mapped_column(String(120), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    unit_types: Mapped[list[UnitType]] = relationship(
        back_populates="project", cascade="all, delete-orphan"
    )

    __table_args__ = (
        Index("ix_projects_area", "area"),
        Index("ix_projects_name", "name"),
    )


class UnitType(Base):
    """One floor plan, within a project. SPEC.md Phase 8.

    ``status`` is the lifecycle stage of the type itself, not of any one
    version: ``draft`` (being worked on, not yet submitted for review),
    ``pending_review`` (a part-timer's submission, or an admin's draft they
    have chosen to verify), ``approved`` (live in the library, quotable), and
    ``superseded`` (reserved for the type as a whole being replaced --
    nothing in this phase sets it; a *version* changing is handled by
    ``UnitTypeVersion`` instead, which is the whole reason versioning exists).

    A **part-timer's submission is never searchable or quotable until an
    admin has approved it** -- the two-step workflow the spec insists on,
    because a plan digitised in a hurry at a fair, wrong by a factor of the
    scale, produces a confident wrong number on every quote after it.

    Variants (``Type A mirror``, ``end lot``, ``corner``) are their own rows
    with ``variant_of`` pointing at the type they are a variant of -- an
    explicit relationship, not an inheritance system, because a mirrored unit
    that shares nine openings and differs in one is easier to read, and safer
    to price from, as its own list than as a diff.
    """

    __tablename__ = "unit_types"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    project_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("projects.id", ondelete="CASCADE")
    )
    name: Mapped[str] = mapped_column(String(120))
    floor_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    variant_of: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("unit_types.id"), nullable=True
    )
    status: Mapped[str] = mapped_column(String(16), default="draft")
    created_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    project: Mapped[Project] = relationship(back_populates="unit_types")
    versions: Mapped[list[UnitTypeVersion]] = relationship(
        back_populates="unit_type",
        cascade="all, delete-orphan",
        order_by="UnitTypeVersion.version",
    )

    __table_args__ = (
        Index("ix_unit_types_project", "project_id"),
        Index("ix_unit_types_status", "status"),
    )


class UnitTypeVersion(Base):
    """A plan changes; history does not. SPEC.md Phase 8.

    **Never updated in place and never deleted** -- the same rule as a rate
    card, for the same reason: a version applies to future quotations and
    never touches an order already instantiated from it (Phase 8's own
    provenance columns on ``OrderLine`` are what let a line still point back
    at the exact version it came from, a year later).

    Both an approval and a rejection are audited with the reviewer's name
    (§6.7). The spec's own column list names only ``approved_by``/
    ``approved_at``; the ``rejected_*`` columns are this file's extension of
    that same requirement to the other half of the same decision -- see
    SPEC.md §13, this phase's open question about what a rejection does to
    the *type's* status.
    """

    __tablename__ = "unit_type_versions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    unit_type_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("unit_types.id", ondelete="CASCADE")
    )
    version: Mapped[int] = mapped_column(Integer)

    approved_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    approved_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    rejected_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    rejected_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    rejection_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: Whatever the admin wants on record about this version -- a correction
    #: made while verifying it, or why it superseded the last one.
    note: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    unit_type: Mapped[UnitType] = relationship(back_populates="versions")
    openings: Mapped[list[Opening]] = relationship(
        back_populates="version", cascade="all, delete-orphan"
    )
    rooms: Mapped[list[Room]] = relationship(
        back_populates="version", cascade="all, delete-orphan"
    )
    floor_plan: Mapped[FloorPlan | None] = relationship(
        back_populates="version", cascade="all, delete-orphan", uselist=False
    )

    __table_args__ = (
        Index(
            "ix_unit_type_versions_unique",
            "unit_type_id",
            "version",
            unique=True,
        ),
    )


class Opening(Base):
    """One window or door, from the developer's schedule. SPEC.md Phase 8.

    The numbers come from the schedule, typed once by an admin who can check
    them -- **never** from reading the uploaded image. ``FloorPlan`` is a
    backdrop for tapping and a reference for the salesperson, not a ruler.
    """

    __tablename__ = "openings"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    unit_type_version_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("unit_type_versions.id", ondelete="CASCADE")
    )
    label: Mapped[str] = mapped_column(String(80))
    room: Mapped[str] = mapped_column(String(80))
    floor: Mapped[int | None] = mapped_column(Integer, nullable=True)
    nominal_w_tmm: Mapped[int] = mapped_column(Integer)
    nominal_h_tmm: Mapped[int] = mapped_column(Integer)
    sort_order: Mapped[int] = mapped_column(Integer, default=0)

    version: Mapped[UnitTypeVersion] = relationship(back_populates="openings")

    __table_args__ = (
        Index("ix_openings_version", "unit_type_version_id", "sort_order"),
    )


class Room(Base):
    """One room's floor, from the developer's schedule. SPEC.md Phase 8.

    What lets "store all floor plans so it can auto-calculate a full SPC
    flooring quote" actually work: the area is typed once here, and a
    whole-house flooring line then prices like any other ``per_sqft`` line --
    no different from a room somebody measured with a tape.

    ``nominal_area_mm2`` is plain mm2, not tenths: a tenth-of-a-millimetre
    squared would demand a rescale on every read for no precision anything
    here needs, and a room's area still fits comfortably under
    ``BigInteger`` at that unit.
    """

    __tablename__ = "rooms"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    unit_type_version_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("unit_type_versions.id", ondelete="CASCADE")
    )
    name: Mapped[str] = mapped_column(String(80))
    floor: Mapped[int | None] = mapped_column(Integer, nullable=True)
    nominal_area_mm2: Mapped[int] = mapped_column(BigInteger)
    skirting_run_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)

    version: Mapped[UnitTypeVersion] = relationship(back_populates="rooms")

    __table_args__ = (Index("ix_rooms_version", "unit_type_version_id"),)


class FloorPlan(Base):
    """The original uploaded document. SPEC.md Phase 8.

    Kept as source material alongside the structured measurements extracted
    from it, so a disputed dimension can be checked against what was
    actually submitted -- the same reasoning that keeps a photo per window on
    the handset (§8).

    ``image_data`` lives in Postgres rather than an object store. There is no
    deployed environment yet to hold a bucket's credentials, and a
    business at this scale's floor plans are a handful of images, not a
    media library -- ``deploy/backup.sh`` already covers this table for free,
    which a separate store would not. If usage ever outgrows a database
    column, the fix is changing what's behind ``GET /api/floor-plans/{id}/
    image``, not the contract in front of it.

    ``scale_tmm_per_px`` is an exact rational written as a string, exactly
    like ``OrderLine.applied_discount_pct`` -- never a float, because it is a
    ratio used to place taps on the image and CLAUDE.md's arithmetic
    invariant does not carve out an exception for "just a calibration aid".
    It plays no part in pricing: the numbers that price a quote are
    ``Opening``/``Room``'s own columns, typed from the schedule, never read
    off the image.
    """

    __tablename__ = "floor_plans"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    unit_type_version_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("unit_type_versions.id", ondelete="CASCADE"), unique=True
    )
    #: The original filename, kept for display. Never a path -- the bytes
    #: are `image_data`, not a file this column points at.
    file_ref: Mapped[str] = mapped_column(String(300))
    content_type: Mapped[str | None] = mapped_column(String(80), nullable=True)
    image_data: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    #: "12/1" style rational: tenths-of-a-millimetre per pixel. Null until an
    #: admin calibrates it by tapping two points of a known dimension.
    scale_tmm_per_px: Mapped[str | None] = mapped_column(String(24), nullable=True)
    uploaded_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    uploaded_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    version: Mapped[UnitTypeVersion] = relationship(back_populates="floor_plan")


class RecognitionJob(Base):
    """A floor plan's recognition run, worked out in the background. Sep
    2026, once the office actually wanted to upload a plan and walk away
    rather than sit watching a locally hosted model think for several
    minutes -- SPEC.md §14.7's own suggested shape for exactly this: "a
    status a client polls... without reaching for infrastructure this
    system does not otherwise run." No job queue, no worker process; a
    FastAPI `BackgroundTasks` call and this table are the whole mechanism.

    One row per attempt, never edited into a different attempt: a retry is
    a new row, so a poller reading the *latest* row for a floor plan never
    sees a stale one's fields overwritten mid-read by a second attempt
    that started later.

    `openings`/`rooms` mirror `ExtractionResult`'s own fields exactly
    (`app/services/recognition.py`) -- stored only so the result outlives
    the one request that kicked it off. Still never production truth:
    nothing here can become an `Opening` or a `Room` except by a person
    reading this row and retyping or copying it into the ordinary
    submission form, the same gate every other proposal in this library
    already goes through.
    """

    __tablename__ = "recognition_jobs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    floor_plan_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("floor_plans.id", ondelete="CASCADE"), index=True
    )
    #: "pending" | "done" | "failed" -- "failed" is this job's own error
    #: (e.g. the image could not be read), never what a configured provider
    #: itself reports about not recognising anything, which is `openings`/
    #: `rooms` empty on an otherwise "done" row.
    status: Mapped[str] = mapped_column(String(16), default="pending")
    provider: Mapped[str | None] = mapped_column(String(32), nullable=True)
    configured: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    openings: Mapped[list] = mapped_column(JsonColumn, default=list)
    rooms: Mapped[list] = mapped_column(JsonColumn, default=list)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    requested_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class Material(Base):
    """A stocked material, tracked so a real order actually consumes real
    stock. SPEC.md Phase 9.

    ``id`` is **server-generated**, the same exception ``Project`` already
    makes and for the same reason: created at a desk with a connection, by
    the one admin role that manages stock (§13 F2), never offline at a fair.

    ``variant_compat`` is a JSON list of the pricing engine's own ``variant``
    keys (`OrderLine.variant`), not a family name -- matching everything
    else in this codebase, stable identifiers over display strings (§14.6).
    It is what `push_measurement`'s auto-allocation hook checks a line
    against; an empty or missing match means "not inventory-tracked", the
    ordinary case for most products.

    ``coverage_per_unit`` and ``reorder_level`` are exact rationals stored as
    text, like ``OrderLine.billed_qty`` -- a box count is still a quantity,
    and CLAUDE.md's arithmetic invariant does not carve out an exception for
    inventory any more than it does for a calibration scale.
    """

    __tablename__ = "materials"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    family: Mapped[str] = mapped_column(String(32))
    variant_compat: Mapped[list] = mapped_column(JsonColumn, default=list)
    code: Mapped[str] = mapped_column(String(64), unique=True)
    names: Mapped[dict] = mapped_column(JsonColumn)
    #: `metre`, `sqft`, `box`, `piece` or `roll`.
    uom: Mapped[str] = mapped_column(String(16))
    #: Billed-quantity units one stock unit covers, e.g. sqft per box. Null
    #: when no exact conversion is known yet (§13 F3) -- allocation then
    #: stays manual for this material, never guessed.
    coverage_per_unit: Mapped[str | None] = mapped_column(String(32), nullable=True)
    reorder_level: Mapped[str | None] = mapped_column(String(32), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    lots: Mapped[list[StockLot]] = relationship(back_populates="material")

    __table_args__ = (Index("ix_materials_family", "family"),)


class StockLot(Base):
    """One physical delivery of a material. SPEC.md Phase 9.

    A **new row per delivery**, never merged into an existing lot by the
    system -- "same code, different lot, visible colour difference" means
    two deliveries of the same material are two lots even when nothing else
    about them differs, unless the person receiving it says otherwise by
    re-using the same ``lot_ref`` (a genuine top-up of one physical batch,
    e.g. a completed backorder).

    ``qty_on_hand`` is **derived from movements, never edited directly by a
    route** -- every write to it happens inside the same service function
    that also inserts the ``StockMovement`` causing it, one transaction,
    the same discipline `Order.final_total_sen` already keeps with its own
    pricing.
    """

    __tablename__ = "stock_lots"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    material_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("materials.id", ondelete="CASCADE")
    )
    lot_ref: Mapped[str] = mapped_column(String(80))
    qty_on_hand: Mapped[str] = mapped_column(String(32))
    #: Free text -- one site (client, Sep 2026: factory and showroom
    #: together), so this is descriptive only, never a join key.
    location: Mapped[str | None] = mapped_column(String(80), nullable=True)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    #: Admin-only on the way out, the same as everywhere else cost appears.
    cost_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    material: Mapped[Material] = relationship(back_populates="lots")

    __table_args__ = (
        Index("ix_stock_lots_material", "material_id"),
        UniqueConstraint(
            "material_id", "lot_ref", name="uq_stock_lots_material_lot_ref"
        ),
    )


class StockMovement(Base):
    """The ledger. APPEND ONLY. SPEC.md Phase 9.

    The one thing that is ever true about stock is what this table says
    happened to it. ``qty_on_hand`` is a convenience the service layer keeps
    in step with this table in the same transaction; if the two ever
    disagree, this table is what is right.
    """

    __tablename__ = "stock_movements"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    material_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("materials.id", ondelete="CASCADE")
    )
    lot_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("stock_lots.id", ondelete="CASCADE")
    )
    #: Exact rational, signed -- positive in, negative out.
    delta: Mapped[str] = mapped_column(String(32))
    #: `receipt`, `allocation`, `release`, `consumption`, `offcut_return`,
    #: `adjustment`, `damage` or `return_to_supplier`. `release` reverses an
    #: `allocation` (an order cancelled after stock was set aside for it);
    #: `consumption` is reserved for a future workshop-side "actually used"
    #: step nothing writes yet (§11 Phase 9).
    reason: Mapped[str] = mapped_column(String(24))
    order_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    by_user_id: Mapped[str] = mapped_column(String(36))
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    note: Mapped[str | None] = mapped_column(Text, nullable=True)

    __table_args__ = (
        Index("ix_stock_movements_lot", "lot_id"),
        Index("ix_stock_movements_material", "material_id"),
    )


class Allocation(Base):
    """One order line's claim on a material. SPEC.md Phase 9.

    Two routes to `approved`, the same one-gate shape the property library
    already uses: an auto-proposable material lands at `proposed` from
    `push_measurement`'s own hook and waits for an admin; everything else is
    created by an admin already at a decision, because there is no automatic
    guess to check.

    `lot_id` is null while `proposed` with no single lot covering the
    quantity -- left for a person to resolve, never a silent multi-lot
    split. A second manual `Allocation` row against the same
    `order_line_id` is how a person actually splits one across two lots.

    Only `approved` ever produces a `StockMovement` (reason `allocation`) and
    decrements a lot; `proposed` and `rejected` never touch stock, which is
    what makes "available to promise" (on-hand minus proposed) a real
    number rather than one two different reads disagree about.
    """

    __tablename__ = "allocations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_line_id: Mapped[str] = mapped_column(String(36))
    order_id: Mapped[str] = mapped_column(String(36))
    material_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("materials.id", ondelete="CASCADE")
    )
    lot_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("stock_lots.id"), nullable=True
    )
    qty: Mapped[str] = mapped_column(String(32))
    #: `proposed`, `approved`, `rejected` or `released`.
    status: Mapped[str] = mapped_column(String(16), default="proposed")
    proposed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    decided_by_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    decided_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    #: Required on a rejection -- the same rule the library's own reviewer
    #: already follows (`reject_unit_type`).
    decision_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    allocated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    released_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    __table_args__ = (
        Index("ix_allocations_order_line", "order_line_id"),
        Index("ix_allocations_material_status", "material_id", "status"),
    )

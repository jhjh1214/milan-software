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

from datetime import datetime

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
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

    width_tmm: Mapped[int] = mapped_column(Integer)
    height_tmm: Mapped[int | None] = mapped_column(Integer, nullable=True)
    raw_width: Mapped[str] = mapped_column(String(32))
    raw_height: Mapped[str] = mapped_column(String(32))
    quantity: Mapped[int] = mapped_column(Integer, default=1)

    #: The device's figure, and the server's. §9.4: on a mismatch, accept the
    #: order and raise it for review. Never lose a sale over a rounding
    #: disagreement, and never silently accept the client's number either.
    device_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    server_total_sen: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    quote: Mapped[Quote] = relationship(back_populates="lines")

    __table_args__ = (Index("ix_quote_lines_quote", "quote_id", "sort_order"),)


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

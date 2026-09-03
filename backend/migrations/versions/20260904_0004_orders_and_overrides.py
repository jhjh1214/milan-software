"""Confirmed orders, their lines, their history, and the override audit log.

Revision ID: 0004
Revises: 0003
Create Date: 2026-09-04
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # A deposit confirms an order, so a row here is money already taken. The id
    # is the device's own UUID and the push is idempotent on it, so a fair's
    # dropped connection cannot produce two orders for one RM300.
    op.create_table(
        "orders",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("quote_id", sa.String(length=36), nullable=False),
        # Issued by the server, never by a device. {branch}-{yymm}-{seq} has no
        # per-device component, so two part-timers offline at one fair would
        # both mint the same one -- and it goes on a document the customer
        # takes away.
        sa.Column("order_no", sa.String(length=32), nullable=True),
        sa.Column("channel", sa.String(length=16), nullable=False),
        sa.Column("pinned_rate_card_version", sa.Integer(), nullable=False),
        sa.Column("customer_name", sa.String(length=120), nullable=True),
        sa.Column("customer_phone", sa.String(length=40), nullable=True),
        sa.Column("delivery_zone_id", sa.String(length=64), nullable=True),
        sa.Column("delivery_charge_sen", sa.BigInteger(), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        # Both kept: the variance report by salesperson is what tells the boss
        # who is guessing badly and needs retraining.
        sa.Column("estimate_total_sen", sa.BigInteger(), nullable=False),
        sa.Column("final_total_sen", sa.BigInteger(), nullable=True),
        sa.Column("deposit_paid_sen", sa.BigInteger(), nullable=False),
        sa.Column("has_unmeasured_lines", sa.Boolean(), nullable=False),
        sa.Column("confirmed_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=True),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["confirmed_by_user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_orders_received", "orders", ["received_at"])
    op.create_index("ix_orders_status", "orders", ["status"])
    op.create_index("ix_orders_quote", "orders", ["quote_id"])
    # An order number identifies one order or it identifies nothing.
    op.create_index("ix_orders_order_no", "orders", ["order_no"], unique=True)

    # Copies, not references. Editing an old quote must not change a confirmed
    # order, and each line snapshots what priced it so the number stays
    # explainable after the card has been superseded twice.
    op.create_table(
        "order_lines",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("order_id", sa.String(length=36), nullable=False),
        sa.Column("quote_line_id", sa.String(length=36), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("room", sa.String(length=80), nullable=False),
        sa.Column("variant", sa.String(length=64), nullable=False),
        sa.Column("material_key", sa.String(length=64), nullable=True),
        sa.Column("layer", sa.String(length=16), nullable=False),
        sa.Column("parent_line_id", sa.String(length=36), nullable=True),
        # Tenths of a millimetre. A column named _mm would be a bug.
        sa.Column("est_width_tmm", sa.Integer(), nullable=False),
        sa.Column("est_height_tmm", sa.Integer(), nullable=True),
        sa.Column("final_width_tmm", sa.Integer(), nullable=True),
        sa.Column("final_height_tmm", sa.Integer(), nullable=True),
        sa.Column("is_site_measured", sa.Boolean(), nullable=False),
        sa.Column("measured_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("measured_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("quantity", sa.Integer(), nullable=False),
        sa.Column("category_lock_id", sa.String(length=36), nullable=True),
        sa.Column("applied_rule_id", sa.String(length=64), nullable=False),
        sa.Column("applied_band_label", sa.String(length=64), nullable=True),
        sa.Column("applied_rate_card_version", sa.Integer(), nullable=False),
        # An exact rational as a string -- "0", "1/10". Never a float: a
        # percentage of a price is money.
        sa.Column("applied_discount_pct", sa.String(length=24), nullable=False),
        sa.Column("standard_rate_sen", sa.BigInteger(), nullable=False),
        sa.Column("rate_sen", sa.BigInteger(), nullable=False),
        sa.Column("billed_qty", sa.String(length=32), nullable=False),
        sa.Column("billed_unit", sa.String(length=16), nullable=False),
        sa.Column("line_total_sen", sa.BigInteger(), nullable=False),
        sa.Column("material_deferred", sa.Boolean(), nullable=False),
        sa.Column("is_overridden", sa.Boolean(), nullable=False),
        sa.ForeignKeyConstraint(["order_id"], ["orders.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_order_lines_order", "order_lines", ["order_id", "sort_order"])

    # APPEND ONLY. This is the history somebody reads a year later to answer
    # what happened to a job.
    op.create_table(
        "order_events",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("order_id", sa.String(length=36), nullable=False),
        sa.Column("event", sa.String(length=32), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("by_user_id", sa.String(length=36), nullable=True),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["order_id"], ["orders.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_order_events_order", "order_events", ["order_id", "at"])

    # APPEND ONLY, and never deletable from the app. This table IS the control
    # on overriding: reason and admin_user_id are both NOT NULL, because a row
    # that cannot say who or why is not an audit trail.
    op.create_table(
        "price_overrides",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("order_line_id", sa.String(length=36), nullable=False),
        # Denormalised off the line for the "overrides this week" screen, which
        # groups by order.
        sa.Column("order_id", sa.String(length=36), nullable=False),
        sa.Column("before_sen", sa.BigInteger(), nullable=False),
        sa.Column("after_sen", sa.BigInteger(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("admin_user_id", sa.String(length=36), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=True),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["order_id"], ["orders.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_price_overrides_at", "price_overrides", ["at"])
    op.create_index("ix_price_overrides_order", "price_overrides", ["order_id"])

    # One counter per branch per month. Opening a second branch must not
    # renumber the first.
    op.create_table(
        "order_counters",
        sa.Column("key", sa.String(length=32), nullable=False),
        sa.Column("next_value", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("key"),
    )


def downgrade() -> None:
    op.drop_table("order_counters")
    op.drop_index("ix_price_overrides_order", table_name="price_overrides")
    op.drop_index("ix_price_overrides_at", table_name="price_overrides")
    op.drop_table("price_overrides")
    op.drop_index("ix_order_events_order", table_name="order_events")
    op.drop_table("order_events")
    op.drop_index("ix_order_lines_order", table_name="order_lines")
    op.drop_table("order_lines")
    op.drop_index("ix_orders_order_no", table_name="orders")
    op.drop_index("ix_orders_quote", table_name="orders")
    op.drop_index("ix_orders_status", table_name="orders")
    op.drop_index("ix_orders_received", table_name="orders")
    op.drop_table("orders")

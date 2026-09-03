"""Payments, and the counter that issues receipt numbers.

Revision ID: 0003
Revises: 0002
Create Date: 2026-09-03
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # APPEND ONLY. A refund is a new row, never an edit to the row it reverses:
    # the cash-up reconciles what happened, not what the drawer looks like now.
    op.create_table(
        "payments",
        # The device's own id. The push is idempotent on it, so a retry after a
        # dropped connection cannot take the same RM300 twice.
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("quote_id", sa.String(length=36), nullable=False),
        sa.Column("category_lock_id", sa.String(length=36), nullable=True),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("amount_sen", sa.BigInteger(), nullable=False),
        sa.Column("method", sa.String(length=24), nullable=False),
        sa.Column("external_ref", sa.String(length=80), nullable=True),
        # Issued by the server, never by a device: it goes on a legal document,
        # and two handsets offline at one fair would invent the same number.
        sa.Column("receipt_no", sa.String(length=32), nullable=True),
        sa.Column("taken_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("taken_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["taken_by_user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_payments_quote", "payments", ["quote_id"])
    op.create_index("ix_payments_taken", "payments", ["taken_at"])
    # A receipt number identifies one payment or it identifies nothing.
    op.create_index("ix_payments_receipt", "payments", ["receipt_no"], unique=True)

    # One row per YYYYMM, incremented under a row lock, so two devices syncing
    # at once cannot be handed the same number.
    op.create_table(
        "receipt_counters",
        sa.Column("period", sa.String(length=6), nullable=False),
        sa.Column("next_value", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("period"),
    )


def downgrade() -> None:
    op.drop_table("receipt_counters")
    op.drop_index("ix_payments_receipt", table_name="payments")
    op.drop_index("ix_payments_taken", table_name="payments")
    op.drop_index("ix_payments_quote", table_name="payments")
    op.drop_table("payments")

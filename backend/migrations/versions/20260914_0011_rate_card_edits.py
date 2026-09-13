"""A staff or admin member changing one product's price directly, live.

Revision ID: 0011
Revises: 0010
Create Date: 2026-09-14

The audit trail for a live per-product price edit -- the same control
``price_overrides`` already is for an order line: a PIN is a speed bump,
and what actually stops abuse is that every move is recorded against a
name, with a reason, and read back later.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "rate_card_edits",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("rule_id", sa.String(length=64), nullable=False),
        sa.Column("list_id", sa.String(length=32), nullable=False),
        sa.Column("before_rate_sen", sa.BigInteger(), nullable=False),
        sa.Column("after_rate_sen", sa.BigInteger(), nullable=False),
        sa.Column("before_mvp_rate_sen", sa.BigInteger(), nullable=True),
        sa.Column("after_mvp_rate_sen", sa.BigInteger(), nullable=True),
        sa.Column("resulting_version", sa.Integer(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("by_user_id", sa.String(length=36), nullable=False),
        sa.Column(
            "at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_rate_card_edits_at", "rate_card_edits", ["at"])


def downgrade() -> None:
    op.drop_index("ix_rate_card_edits_at", table_name="rate_card_edits")
    op.drop_table("rate_card_edits")

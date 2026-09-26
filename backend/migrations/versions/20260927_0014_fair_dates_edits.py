"""An admin changing when a fair runs, audited.

Revision ID: 0014
Revises: 0013
Create Date: 2026-09-27

The fair card's promo window decides which days fair prices are quoted and
when every deposit from that fair stops holding its price (SPEC.md §6.1), so
a change to it is recorded against a name with a reason -- the same control
``rate_card_edits`` is for one product's price.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0014"
down_revision: str | None = "0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "fair_dates_edits",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("before_code", sa.String(length=64), nullable=True),
        sa.Column("before_valid_from", sa.Date(), nullable=True),
        sa.Column("before_valid_to", sa.Date(), nullable=True),
        sa.Column("after_code", sa.String(length=64), nullable=False),
        sa.Column("after_valid_from", sa.Date(), nullable=False),
        sa.Column("after_valid_to", sa.Date(), nullable=False),
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
    op.create_index("ix_fair_dates_edits_at", "fair_dates_edits", ["at"])


def downgrade() -> None:
    op.drop_index("ix_fair_dates_edits_at", table_name="fair_dates_edits")
    op.drop_table("fair_dates_edits")

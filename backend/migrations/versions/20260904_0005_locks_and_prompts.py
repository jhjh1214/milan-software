"""Rate locks and the deposit prompt log, so a hold is not one handset's secret.

Revision ID: 0005
Revises: 0004
Create Date: 2026-09-04
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Held on the server as well as on the device. The device half only answers
    # for the handset that took the deposit: six phones work a fair, the
    # customer deposits on phone 3, and walks into the showroom in March where
    # phone 1 is used. Without this the customer is quoted the standard rate --
    # more than the hold they paid for.
    op.create_table(
        "category_locks",
        sa.Column("id", sa.String(length=36), nullable=False),
        # A normalised phone where there is one, quote:<id> where there is not.
        # SPEC.md 13 B9 decides the proper customer record.
        sa.Column("customer_key", sa.String(length=64), nullable=False),
        sa.Column("category", sa.String(length=16), nullable=False),
        sa.Column("deposit_payment_id", sa.String(length=36), nullable=True),
        # Both pinned. Pinning only the version silently reprices this customer
        # when the promo percentage moves.
        sa.Column("held_rate_card_version", sa.Integer(), nullable=False),
        # An exact rational as a string. Never a float: a percentage of a price
        # is money.
        sa.Column("held_discount_pct", sa.String(length=24), nullable=False),
        sa.Column("held_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("opened_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("opened_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=True),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_category_locks_customer", "category_locks", ["customer_key", "status"]
    )
    # 6.1: UNIQUE(customer_id, category) WHERE status = 'active'. Two active
    # holds on one category would make "which rate did the RM300 buy" a
    # question with two answers.
    op.create_index(
        "ix_category_locks_one_active",
        "category_locks",
        ["customer_key", "category"],
        unique=True,
        postgresql_where=sa.text("status = 'active'"),
        sqlite_where=sa.text("status = 'active'"),
    )

    # APPEND ONLY. The declined-deposit report only exists if a decline is
    # recorded as carefully as a sale.
    op.create_table(
        "deposit_prompts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("quote_id", sa.String(length=36), nullable=False),
        sa.Column("category", sa.String(length=16), nullable=False),
        # collected, declined, lines_removed or dismissed. Dismissed is kept
        # distinct: "they said no" and "nobody asked properly" are different
        # problems, and only one of them is the customer's.
        sa.Column("choice", sa.String(length=16), nullable=False),
        # What the category was worth when the question was asked, so the
        # report can say what was left on the table.
        sa.Column("category_subtotal_sen", sa.BigInteger(), nullable=False),
        sa.Column("by_user_id", sa.String(length=36), nullable=True),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=True),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_deposit_prompts_at", "deposit_prompts", ["at"])
    op.create_index("ix_deposit_prompts_quote", "deposit_prompts", ["quote_id"])


def downgrade() -> None:
    op.drop_index("ix_deposit_prompts_quote", table_name="deposit_prompts")
    op.drop_index("ix_deposit_prompts_at", table_name="deposit_prompts")
    op.drop_table("deposit_prompts")
    op.drop_index("ix_category_locks_one_active", table_name="category_locks")
    op.drop_index("ix_category_locks_customer", table_name="category_locks")
    op.drop_table("category_locks")

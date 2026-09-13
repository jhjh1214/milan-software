"""A per_sqft line can price from a pre-known area. SPEC.md's property
library, "auto-calculate a full SPC flooring quote".

Revision ID: 0010
Revises: 0009
Create Date: 2026-09-13

A saved room's ``nominal_area_mm2`` stores only the resulting area -- a real
room is not always a rectangle, so there is no width/length pair to keep.
``width_tmm``/``est_width_tmm`` widen to nullable for exactly that one case,
and a new ``direct_area_sqft`` (exact rational as text, the same convention
as ``billed_qty``) carries the pre-known area through the pipeline. Never set
at final pricing -- site measurement remains production truth.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # `batch_alter_table`, not a bare `alter_column`: SQLite has no `ALTER
    # COLUMN`, and this is the first migration in this project to widen a
    # constraint rather than only add. Alembic's batch mode recreates the
    # table under the hood on SQLite and runs the plain `ALTER TABLE` on
    # Postgres -- one migration, correct on both.
    with op.batch_alter_table("quote_lines") as batch:
        batch.alter_column("width_tmm", existing_type=sa.Integer(), nullable=True)
        batch.add_column(
            sa.Column("direct_area_sqft", sa.String(length=40), nullable=True)
        )

    with op.batch_alter_table("order_lines") as batch:
        batch.alter_column("est_width_tmm", existing_type=sa.Integer(), nullable=True)
        batch.add_column(
            sa.Column("direct_area_sqft", sa.String(length=40), nullable=True)
        )


def downgrade() -> None:
    with op.batch_alter_table("order_lines") as batch:
        batch.drop_column("direct_area_sqft")
        batch.alter_column("est_width_tmm", existing_type=sa.Integer(), nullable=False)

    with op.batch_alter_table("quote_lines") as batch:
        batch.drop_column("direct_area_sqft")
        batch.alter_column("width_tmm", existing_type=sa.Integer(), nullable=False)

"""A floor plan's recognition run, worked out in the background. SPEC.md
§14.7's own suggested shape for a genuinely long-running capability call --
a status a client polls -- since a locally hosted model on modest hardware
can take minutes where a hosted one takes seconds.

Revision ID: 0012
Revises: 0011
Create Date: 2026-09-15
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

#: JSONB on Postgres, plain JSON elsewhere -- matches app/models/db.py's own
#: JsonColumn, and 0009's own precedent for the same split.
JsonColumn = sa.JSON().with_variant(JSONB(), "postgresql")


def upgrade() -> None:
    op.create_table(
        "recognition_jobs",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("floor_plan_id", sa.String(length=36), nullable=False),
        sa.Column(
            "status", sa.String(length=16), nullable=False, server_default="pending"
        ),
        sa.Column("provider", sa.String(length=32), nullable=True),
        sa.Column("configured", sa.Boolean(), nullable=True),
        sa.Column("openings", JsonColumn, nullable=False),
        sa.Column("rooms", JsonColumn, nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("requested_by_user_id", sa.String(length=36), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["floor_plan_id"], ["floor_plans.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_recognition_jobs_floor_plan_id",
        "recognition_jobs",
        ["floor_plan_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_recognition_jobs_floor_plan_id", table_name="recognition_jobs")
    op.drop_table("recognition_jobs")

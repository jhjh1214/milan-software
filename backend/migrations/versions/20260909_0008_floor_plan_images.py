"""Floor plan images, stored in Postgres. SPEC.md Phase 8.

Revision ID: 0008
Revises: 0007
Create Date: 2026-09-09

No object store is configured anywhere in this deploy yet, and a business
at this scale's floor plans are a handful of images, not a media library --
``deploy/backup.sh`` already covers this table, which a separate store
would not. If usage ever outgrows a database column, the fix is what is
behind the image-serving endpoint, not this migration.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "floor_plans", sa.Column("content_type", sa.String(length=80), nullable=True)
    )
    op.add_column(
        "floor_plans", sa.Column("image_data", sa.LargeBinary(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("floor_plans", "image_data")
    op.drop_column("floor_plans", "content_type")

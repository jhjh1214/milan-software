"""A free-text address, typed in by staff planning the day's route. SPEC.md
§13 C10's write-up: no structured address/geocoding, just enough to open a
free Google Maps search link before a site visit.

Revision ID: 0013
Revises: 0012
Create Date: 2026-09-23
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "orders",
        sa.Column("site_address_note", sa.String(length=240), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("orders", "site_address_note")

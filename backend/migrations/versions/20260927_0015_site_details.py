"""Where a visit is, and when the house can be measured. SPEC.md §13 C10.

Revision ID: 0015
Revises: 0014
Create Date: 2026-09-27

A postcode to group a day's trips by, the first day the house is ready
(keys handed over), and when these were last captured -- the handset and the
office's dashboard both write them, so an older push must be refusable.
All nullable: an address is never required to take a deposit.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0015"
down_revision: str | None = "0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("orders") as batch:
        batch.add_column(sa.Column("site_postcode", sa.String(length=5), nullable=True))
        batch.add_column(sa.Column("site_ready_from", sa.Date(), nullable=True))
        batch.add_column(
            sa.Column("site_captured_at", sa.DateTime(timezone=True), nullable=True)
        )


def downgrade() -> None:
    with op.batch_alter_table("orders") as batch:
        batch.drop_column("site_captured_at")
        batch.drop_column("site_ready_from")
        batch.drop_column("site_postcode")

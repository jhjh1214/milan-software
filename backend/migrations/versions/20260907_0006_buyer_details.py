"""Buyer details on the server, so they are not one handset's secret.

Revision ID: 0006
Revises: 0005
Create Date: 2026-09-07
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # SPEC.md 10.3. The details an e-invoice needs, captured on the handset
    # while the customer is standing there and pushed like everything else.
    #
    # The reason this is a migration rather than device-only storage: the
    # OFFICE runs the SQL Account export, and details that never leave a phone
    # are the same as no details as far as the accounts system is concerned.
    # That is exactly the failure the rate locks had before 0005 -- correct
    # machinery, stored somewhere nothing else could read.
    #
    # All nullable. Most orders are walk-ins who are General Public and need
    # none of it, and what counts as COMPLETE is a rule in
    # app/pricing/einvoice_threshold.py rather than a flag on the row -- a tick
    # box gets ticked by anyone in a hurry, and this row is what a real invoice
    # gets built from.
    for column in (
        sa.Column("buyer_tin", sa.String(length=32), nullable=True),
        # nric / brn / passport / army. Stored with its number or not at all:
        # a number with no type cannot be filed.
        sa.Column("buyer_id_type", sa.String(length=16), nullable=True),
        sa.Column("buyer_id_number", sa.String(length=64), nullable=True),
        sa.Column("buyer_address_line1", sa.String(length=160), nullable=True),
        sa.Column("buyer_address_line2", sa.String(length=160), nullable=True),
        sa.Column("buyer_city", sa.String(length=80), nullable=True),
        sa.Column("buyer_state", sa.String(length=80), nullable=True),
        sa.Column("buyer_postcode", sa.String(length=16), nullable=True),
        # Business buyers only.
        sa.Column("buyer_msic_code", sa.String(length=16), nullable=True),
    ):
        op.add_column("orders", column)

    # 10.3: the customer may ask for an e-invoice at any value, so this is a
    # reason to capture on its own. Defaulted rather than nullable, because
    # "nobody asked" and "we do not know" are the same thing here and a
    # three-state answer would only invite a wrong reading of the null.
    op.add_column(
        "orders",
        sa.Column(
            "einvoice_requested",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )

    # When the device recorded them.
    #
    # Several handsets work one fair and any of them can capture for an order,
    # so a push can arrive after a newer one has already landed. This is the
    # only ordering signal available offline, and the endpoint uses it to
    # refuse a stale write rather than letting the last arrival win. Nullable
    # because every order that exists today has no capture at all.
    op.add_column(
        "orders",
        sa.Column("buyer_captured_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    for name in (
        "buyer_captured_at",
        "einvoice_requested",
        "buyer_msic_code",
        "buyer_postcode",
        "buyer_state",
        "buyer_city",
        "buyer_address_line2",
        "buyer_address_line1",
        "buyer_id_number",
        "buyer_id_type",
        "buyer_tin",
    ):
        op.drop_column("orders", name)

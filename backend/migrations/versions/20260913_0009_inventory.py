"""Inventory: materials, lots, the movement ledger, allocations. SPEC.md
Phase 9.

Revision ID: 0009
Revises: 0008
Create Date: 2026-09-13

Built once §13 F2 had a real answer (the office's own purchasing person) --
"tell the client before they buy it" was the phase's own warning against
building a ledger nobody is accountable for.

``qty_on_hand``, ``coverage_per_unit``, ``reorder_level``, ``delta`` and
``qty`` are all exact rationals stored as text, the same convention as
``order_lines.billed_qty`` -- CLAUDE.md's arithmetic invariant does not
carve out an exception for a box count.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

#: Mirrors ``app.models.db.JsonColumn``. Repeated rather than imported -- a
#: migration is a snapshot of the schema at a point in time.
JsonColumn = sa.JSON().with_variant(JSONB(), "postgresql")


def upgrade() -> None:
    op.create_table(
        "materials",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("family", sa.String(length=32), nullable=False),
        sa.Column("variant_compat", JsonColumn, nullable=False),
        sa.Column("code", sa.String(length=64), nullable=False),
        sa.Column("names", JsonColumn, nullable=False),
        # metre | sqft | box | piece | roll
        sa.Column("uom", sa.String(length=16), nullable=False),
        sa.Column("coverage_per_unit", sa.String(length=32), nullable=True),
        sa.Column("reorder_level", sa.String(length=32), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("code"),
    )
    op.create_index("ix_materials_family", "materials", ["family"])

    op.create_table(
        "stock_lots",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("material_id", sa.String(length=36), nullable=False),
        sa.Column("lot_ref", sa.String(length=80), nullable=False),
        sa.Column("qty_on_hand", sa.String(length=32), nullable=False),
        sa.Column("location", sa.String(length=80), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        # admin-only on the way out
        sa.Column("cost_sen", sa.BigInteger(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(["material_id"], ["materials.id"], ondelete="CASCADE"),
        sa.UniqueConstraint(
            "material_id", "lot_ref", name="uq_stock_lots_material_lot_ref"
        ),
    )
    op.create_index("ix_stock_lots_material", "stock_lots", ["material_id"])

    op.create_table(
        "stock_movements",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("material_id", sa.String(length=36), nullable=False),
        sa.Column("lot_id", sa.String(length=36), nullable=False),
        # signed exact rational: positive in, negative out
        sa.Column("delta", sa.String(length=32), nullable=False),
        # receipt | allocation | release | consumption | offcut_return |
        # adjustment | damage | return_to_supplier
        sa.Column("reason", sa.String(length=24), nullable=False),
        sa.Column("order_id", sa.String(length=36), nullable=True),
        sa.Column("by_user_id", sa.String(length=36), nullable=False),
        sa.Column(
            "at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("note", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(["material_id"], ["materials.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["lot_id"], ["stock_lots.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_stock_movements_lot", "stock_movements", ["lot_id"])
    op.create_index("ix_stock_movements_material", "stock_movements", ["material_id"])

    op.create_table(
        "allocations",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("order_line_id", sa.String(length=36), nullable=False),
        sa.Column("order_id", sa.String(length=36), nullable=False),
        sa.Column("material_id", sa.String(length=36), nullable=False),
        sa.Column("lot_id", sa.String(length=36), nullable=True),
        sa.Column("qty", sa.String(length=32), nullable=False),
        # proposed | approved | rejected | released
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column(
            "proposed_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("decided_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decision_note", sa.Text(), nullable=True),
        sa.Column("allocated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("released_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(["material_id"], ["materials.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["lot_id"], ["stock_lots.id"]),
    )
    op.create_index("ix_allocations_order_line", "allocations", ["order_line_id"])
    op.create_index(
        "ix_allocations_material_status", "allocations", ["material_id", "status"]
    )


def downgrade() -> None:
    op.drop_index("ix_allocations_material_status", table_name="allocations")
    op.drop_index("ix_allocations_order_line", table_name="allocations")
    op.drop_table("allocations")

    op.drop_index("ix_stock_movements_material", table_name="stock_movements")
    op.drop_index("ix_stock_movements_lot", table_name="stock_movements")
    op.drop_table("stock_movements")

    op.drop_index("ix_stock_lots_material", table_name="stock_lots")
    op.drop_table("stock_lots")

    op.drop_index("ix_materials_family", table_name="materials")
    op.drop_table("materials")

"""Property / Project / Unit Library. SPEC.md Phase 8.

Revision ID: 0007
Revises: 0006
Create Date: 2026-09-09

Reference property measurements are NOT site measurements -- this whole
phase accelerates *quoting*, and every dimension it stores has to reach a
real order through the same site visit every other line takes. That is what
the new columns on ``order_lines`` are for: an enum from day one, because
adding a third measurement source later to a boolean ``is_site_measured``
would be a migration across every order ever written, and this is exactly
that third source.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "projects",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=160), nullable=False),
        sa.Column("developer", sa.String(length=160), nullable=True),
        sa.Column("area", sa.String(length=120), nullable=True),
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
    )
    op.create_index("ix_projects_area", "projects", ["area"])
    op.create_index("ix_projects_name", "projects", ["name"])

    op.create_table(
        "unit_types",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("project_id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("floor_count", sa.Integer(), nullable=True),
        sa.Column("variant_of", sa.String(length=36), nullable=True),
        # draft | pending_review | approved | superseded
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("created_by_user_id", sa.String(length=36), nullable=True),
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
        sa.ForeignKeyConstraint(["project_id"], ["projects.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["variant_of"], ["unit_types.id"]),
    )
    op.create_index("ix_unit_types_project", "unit_types", ["project_id"])
    op.create_index("ix_unit_types_status", "unit_types", ["status"])

    op.create_table(
        "unit_type_versions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("unit_type_id", sa.String(length=36), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("approved_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("rejected_by_user_id", sa.String(length=36), nullable=True),
        sa.Column("rejected_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("rejection_reason", sa.Text(), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_by_user_id", sa.String(length=36), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["unit_type_id"], ["unit_types.id"], ondelete="CASCADE"
        ),
    )
    op.create_index(
        "ix_unit_type_versions_unique",
        "unit_type_versions",
        ["unit_type_id", "version"],
        unique=True,
    )

    op.create_table(
        "openings",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("unit_type_version_id", sa.String(length=36), nullable=False),
        sa.Column("label", sa.String(length=80), nullable=False),
        sa.Column("room", sa.String(length=80), nullable=False),
        sa.Column("floor", sa.Integer(), nullable=True),
        sa.Column("nominal_w_tmm", sa.Integer(), nullable=False),
        sa.Column("nominal_h_tmm", sa.Integer(), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["unit_type_version_id"], ["unit_type_versions.id"], ondelete="CASCADE"
        ),
    )
    op.create_index(
        "ix_openings_version", "openings", ["unit_type_version_id", "sort_order"]
    )

    op.create_table(
        "rooms",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("unit_type_version_id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=80), nullable=False),
        sa.Column("floor", sa.Integer(), nullable=True),
        sa.Column("nominal_area_mm2", sa.BigInteger(), nullable=False),
        sa.Column("skirting_run_tmm", sa.Integer(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["unit_type_version_id"], ["unit_type_versions.id"], ondelete="CASCADE"
        ),
    )
    op.create_index("ix_rooms_version", "rooms", ["unit_type_version_id"])

    op.create_table(
        "floor_plans",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("unit_type_version_id", sa.String(length=36), nullable=False),
        sa.Column("file_ref", sa.String(length=300), nullable=False),
        sa.Column("scale_tmm_per_px", sa.String(length=24), nullable=True),
        sa.Column("uploaded_by_user_id", sa.String(length=36), nullable=True),
        sa.Column(
            "uploaded_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.ForeignKeyConstraint(
            ["unit_type_version_id"], ["unit_type_versions.id"], ondelete="CASCADE"
        ),
        sa.UniqueConstraint("unit_type_version_id"),
    )

    # Provenance on the order line itself (§ "never copy a number and lose
    # where it came from"). Nullable / defaulted so every line ever written
    # before this migration reads as `manual`, which is the truth for all of
    # them -- nothing before Phase 8 could have come from anywhere else.
    op.add_column(
        "order_lines",
        sa.Column(
            "measurement_source",
            sa.String(length=16),
            nullable=False,
            server_default="manual",
        ),
    )
    op.add_column(
        "order_lines",
        sa.Column("source_project_id", sa.String(length=36), nullable=True),
    )
    op.add_column(
        "order_lines",
        sa.Column("source_unit_type_id", sa.String(length=36), nullable=True),
    )
    op.add_column(
        "order_lines", sa.Column("source_version", sa.Integer(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("order_lines", "source_version")
    op.drop_column("order_lines", "source_unit_type_id")
    op.drop_column("order_lines", "source_project_id")
    op.drop_column("order_lines", "measurement_source")

    op.drop_table("floor_plans")
    op.drop_index("ix_rooms_version", table_name="rooms")
    op.drop_table("rooms")
    op.drop_index("ix_openings_version", table_name="openings")
    op.drop_table("openings")
    op.drop_index("ix_unit_type_versions_unique", table_name="unit_type_versions")
    op.drop_table("unit_type_versions")
    op.drop_index("ix_unit_types_status", table_name="unit_types")
    op.drop_index("ix_unit_types_project", table_name="unit_types")
    op.drop_table("unit_types")
    op.drop_index("ix_projects_name", table_name="projects")
    op.drop_index("ix_projects_area", table_name="projects")
    op.drop_table("projects")

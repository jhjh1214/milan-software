"""Users, device sessions, the login ledger, and who took a quote.

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-02
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("phone", sa.String(length=40), nullable=True),
        sa.Column("email", sa.String(length=120), nullable=True),
        # admin | staff | parttime. §3: one wizard for all three, only rate
        # visibility differs.
        sa.Column("role", sa.String(length=16), nullable=False),
        # scrypt, individual. SPEC.md §6.5: one shared password reaches every
        # part-timer within a month, and then the audit log names nobody.
        sa.Column("pin_hash", sa.Text(), nullable=True),
        sa.Column("language", sa.String(length=4), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("deactivated_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    # Unique where present: it is the login identifier. Both dialects allow
    # repeated NULLs in a unique index, so office staff with no phone are fine.
    op.create_index("ix_users_phone", "users", ["phone"], unique=True)

    # No expiry column, on purpose. SPEC.md §12: "Indefinite. No token expiry
    # that locks a user out." Revocation is the control instead.
    op.create_table(
        "device_sessions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("device_id", sa.String(length=36), nullable=False),
        sa.Column("device_label", sa.String(length=80), nullable=True),
        # SHA-256 of the token. The token itself is never stored, so a leaked
        # dump does not hand over live sessions.
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_reason", sa.Text(), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_device_sessions_token", "device_sessions", ["token_hash"], unique=True
    )
    op.create_index("ix_device_sessions_user", "device_sessions", ["user_id"])

    # APPEND ONLY. Both the record of who signed in where, and what the login
    # throttle counts -- scrypt makes an offline attack expensive but does
    # nothing about guessing a four-digit PIN over HTTP.
    op.create_table(
        "login_attempts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("phone", sa.String(length=40), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=True),
        sa.Column("device_id", sa.String(length=36), nullable=True),
        sa.Column("succeeded", sa.Boolean(), nullable=False),
        sa.Column(
            "at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    # The throttle's query: failures for one phone inside a window.
    op.create_index("ix_login_attempts_phone_at", "login_attempts", ["phone", "at"])

    # Batch mode so SQLite gets a table rebuild rather than an ALTER it cannot
    # do; on Postgres this is a plain ADD COLUMN.
    with op.batch_alter_table("quotes") as batch:
        batch.add_column(
            sa.Column("taken_by_user_id", sa.String(length=36), nullable=True)
        )
        batch.create_foreign_key(
            "fk_quotes_taken_by_user_id_users", "users", ["taken_by_user_id"], ["id"]
        )


def downgrade() -> None:
    with op.batch_alter_table("quotes") as batch:
        batch.drop_constraint("fk_quotes_taken_by_user_id_users", type_="foreignkey")
        batch.drop_column("taken_by_user_id")

    op.drop_index("ix_login_attempts_phone_at", table_name="login_attempts")
    op.drop_table("login_attempts")
    op.drop_index("ix_device_sessions_user", table_name="device_sessions")
    op.drop_index("ix_device_sessions_token", table_name="device_sessions")
    op.drop_table("device_sessions")
    op.drop_index("ix_users_phone", table_name="users")
    op.drop_table("users")

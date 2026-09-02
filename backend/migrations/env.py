"""Alembic environment.

The URL comes from ``DATABASE_URL`` and nowhere else, so the same migration
runs against Compose, a test container and the VPS unchanged.

``render_as_batch`` is on because the schema tests run on SQLite, which cannot
``ALTER`` a column in place; batch mode rewrites the table instead. Production
is Postgres and never takes that path.
"""

from __future__ import annotations

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.db import DATABASE_URL
from app.models.db import Base

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Only when the caller has not already chosen one. ``alembic.ini`` never sets
# a URL, so in normal use this is DATABASE_URL; the schema tests set it on the
# Config object to point at a throwaway database, and must win.
if not config.get_main_option("sqlalchemy.url", None):
    config.set_main_option(
        "sqlalchemy.url", os.environ.get("DATABASE_URL", DATABASE_URL)
    )

#: What ``--autogenerate`` compares against, and what the schema test asserts
#: the migrations arrive at.
target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
            render_as_batch=connection.dialect.name == "sqlite",
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()

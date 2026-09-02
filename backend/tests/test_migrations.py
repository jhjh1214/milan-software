"""The migrations must arrive at exactly the schema the models describe.

Two files describing one schema is two chances to be wrong. The failure is
quiet and late: `Base.metadata.create_all` is what the tests run against, so a
model change with no matching migration passes every other test in this suite
and only breaks on the VPS, after deploy, against real customer data.

So this asserts the two agree, by upgrading a blank database and asking Alembic
itself what still differs.

Runs on SQLite by default, and on whatever ``TEST_DATABASE_URL`` names when one
is set -- CI points that at a real Postgres, which is the only place the JSONB
column and the partial indexes are genuinely exercised.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import Engine, create_engine, inspect, text

from app.models.db import Base

BACKEND = Path(__file__).resolve().parents[1]


def alembic_config(url: str) -> Config:
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


@pytest.fixture
def url(tmp_path: Path) -> Iterator[str]:
    """A blank database. Postgres when CI provides one, else a SQLite file.

    A file rather than ``sqlite://``: an in-memory database is per-connection,
    and Alembic opens its own.
    """
    configured = os.environ.get("TEST_DATABASE_URL")
    if not configured:
        yield f"sqlite:///{tmp_path / 'schema.db'}"
        return

    engine = create_engine(configured)
    with engine.begin() as conn:
        # Each test starts from nothing, including any alembic_version row a
        # previous test left behind.
        conn.execute(text("DROP SCHEMA public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
    engine.dispose()
    yield configured


@pytest.fixture
def engine(url: str) -> Iterator[Engine]:
    eng = create_engine(url)
    yield eng
    eng.dispose()


def differences(engine: Engine) -> list:
    with engine.connect() as conn:
        context = MigrationContext.configure(
            conn,
            opts={
                "compare_type": True,
                # The version table is Alembic's own bookkeeping and is not in
                # the models by design.
                "include_name": lambda name, type_, parent: (
                    not (type_ == "table" and name == "alembic_version")
                ),
            },
        )
        return list(compare_metadata(context, Base.metadata))


def test_upgrade_head_matches_the_models(engine: Engine, url: str) -> None:
    # The whole point of the file. If this fails, someone changed a model and
    # did not write the migration -- or wrote one that does something subtly
    # different.
    command.upgrade(alembic_config(url), "head")
    assert differences(engine) == []


def test_every_table_the_models_declare_is_created(engine: Engine, url: str) -> None:
    command.upgrade(alembic_config(url), "head")
    created = set(inspect(engine).get_table_names())
    assert set(Base.metadata.tables) <= created


def test_downgrade_leaves_nothing_behind(engine: Engine, url: str) -> None:
    # A migration that cannot be undone cannot be practised. The restore drill
    # in section 12 is worthless if the only way to test it is on production.
    cfg = alembic_config(url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")

    left = set(inspect(engine).get_table_names()) - {"alembic_version"}
    assert left == set()


def test_upgrade_is_repeatable_after_a_downgrade(engine: Engine, url: str) -> None:
    cfg = alembic_config(url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    assert differences(engine) == []


def test_the_active_rate_card_index_is_partial(engine: Engine, url: str) -> None:
    # Not decoration. A plain unique index on list_id would forbid keeping
    # superseded versions, and CLAUDE.md requires that rate card rows are never
    # deleted -- a quote priced at v1 has to stay explainable after v2 exists.
    command.upgrade(alembic_config(url), "head")

    with engine.begin() as conn:
        if engine.dialect.name == "postgresql":
            sql = text("SELECT indexdef FROM pg_indexes WHERE indexname = :n")
        else:
            sql = text("SELECT sql FROM sqlite_master WHERE name = :n")
        ddl = conn.execute(sql, {"n": "ix_rate_cards_active"}).scalar_one()

    assert "WHERE" in ddl.upper(), ddl

"""Database session handling.

One node, Postgres, Docker Compose (CLAUDE.md). No connection pooling
cleverness: this is one VPS serving a handful of phones and one dashboard, and
the right shape for that is the boring one.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

#: Overridable so tests and the Compose file can point elsewhere. Defaults to
#: the Compose service name, which is what runs in production.
DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql+psycopg://milan:milan@db:5432/milan"
)

_engine = None
_Session: sessionmaker[Session] | None = None


def engine():
    global _engine
    if _engine is None:
        _engine = create_engine(DATABASE_URL, pool_pre_ping=True, future=True)
    return _engine


def session_factory() -> sessionmaker[Session]:
    global _Session
    if _Session is None:
        _Session = sessionmaker(bind=engine(), expire_on_commit=False)
    return _Session


@contextmanager
def session_scope() -> Iterator[Session]:
    """A session that commits on success and rolls back on anything else.

    A half-applied push is worse than a rejected one: the device would see a
    failure, retry, and find the quote already there.
    """
    session = session_factory()()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def configure(url: str) -> None:
    """Points the app at a different database. Used by tests and by Compose."""
    global DATABASE_URL, _engine, _Session
    DATABASE_URL = url
    _engine = None
    _Session = None

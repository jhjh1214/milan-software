"""The operator commands.

Worth testing because they are the ones nobody runs twice: making the first
admin on a new box, revoking a stolen handset, deactivating a leaver. If those
are broken it is found at the worst moment, by someone who cannot get in.

The two that matter most here are the ones about not leaking a PIN: it is never
read from argv, and never printed back.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app import cli
from app import db as db_module
from app.core.security import verify_pin
from app.models.db import Base, DeviceSession, User
from app.services.auth import authenticate, issue_session, resolve_token


@pytest.fixture
def db(monkeypatch: pytest.MonkeyPatch) -> Iterator[sessionmaker[Session]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    monkeypatch.setattr(db_module, "_engine", engine)
    monkeypatch.setattr(db_module, "_Session", factory)
    yield factory
    engine.dispose()


@pytest.fixture
def pin(monkeypatch: pytest.MonkeyPatch):
    """Feeds the PIN prompt, the way a terminal would."""

    def feed(value: str) -> None:
        monkeypatch.setattr(cli, "read_pin", lambda confirm=True: value)

    return feed


class TestCreatingTheFirstAdmin:
    def test_a_user_is_created_and_can_sign_in(self, db, pin) -> None:
        # The whole point: on a fresh box there is no admin, no register
        # endpoint, and no bootstrap password in the image.
        pin("4821")
        assert (
            cli.main(
                ["users", "add", "--name", "Boss", "--phone", "0123", "--role", "admin"]
            )
            == 0
        )

        with db() as session:
            user = authenticate(session, phone="0123", pin="4821")
            assert user.role == "admin"

    def test_the_pin_is_stored_hashed(self, db, pin) -> None:
        pin("4821")
        cli.main(["users", "add", "--name", "Boss", "--phone", "0123"])

        with db() as session:
            stored = session.scalars(select(User)).one().pin_hash
            assert stored is not None
            assert "4821" not in stored
            assert verify_pin("4821", stored)

    def test_a_weak_pin_is_refused_and_nothing_is_created(self, db, pin) -> None:
        pin("0000")
        with pytest.raises(SystemExit):
            cli.main(["users", "add", "--name", "Boss", "--phone", "0123"])

        with db() as session:
            assert session.scalars(select(User)).all() == []

    def test_a_duplicate_phone_is_refused(self, db, pin) -> None:
        # The phone is the login identifier, so two people sharing one is two
        # people who cannot both sign in.
        pin("4821")
        cli.main(["users", "add", "--name", "Boss", "--phone", "0123"])
        with pytest.raises(SystemExit):
            cli.main(["users", "add", "--name", "Someone Else", "--phone", "0123"])

    def test_the_default_role_is_the_least_privileged(self, db, pin) -> None:
        pin("4821")
        cli.main(["users", "add", "--name", "Helper", "--phone", "0123"])

        with db() as session:
            assert session.scalars(select(User)).one().role == "parttime"

    def test_the_pin_is_not_an_argument(self) -> None:
        # An argument lands in shell history and in ps output. This is the
        # check that the flag never gets added "for convenience".
        parser = cli.build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(
                ["users", "add", "--name", "Boss", "--phone", "0123", "--pin", "4821"]
            )


class TestLeavers:
    def test_deactivating_kills_their_live_sessions(self, db, pin) -> None:
        pin("4821")
        cli.main(["users", "add", "--name", "Ah Lian", "--phone", "0123"])

        with db() as session:
            user = session.scalars(select(User)).one()
            token, _ = issue_session(session, user=user, device_id="d1")
            session.commit()

        assert cli.main(["users", "deactivate", "--phone", "0123"]) == 0

        with db() as session:
            assert resolve_token(session, token) is None

    def test_the_user_row_is_kept(self, db, pin) -> None:
        # Their quotes and payments still have to name them.
        pin("4821")
        cli.main(["users", "add", "--name", "Ah Lian", "--phone", "0123"])
        cli.main(["users", "deactivate", "--phone", "0123"])

        with db() as session:
            user = session.scalars(select(User)).one()
            assert user.is_active is False
            assert user.deactivated_at is not None

    def test_deactivating_someone_who_does_not_exist_is_an_error(self, db) -> None:
        with pytest.raises(SystemExit):
            cli.main(["users", "deactivate", "--phone", "0999"])


class TestSessions:
    def test_a_stolen_handset_can_be_revoked_by_id(self, db, pin) -> None:
        pin("4821")
        cli.main(["users", "add", "--name", "Ah Lian", "--phone", "0123"])

        with db() as session:
            user = session.scalars(select(User)).one()
            token, row = issue_session(session, user=user, device_id="d1")
            session_id = row.id
            session.commit()

        assert cli.main(["sessions", "revoke", session_id, "--reason", "lost"]) == 0

        with db() as session:
            assert resolve_token(session, token) is None
            assert session.get(DeviceSession, session_id).revoked_reason == "lost"

    def test_revoking_an_unknown_session_is_an_error(self, db) -> None:
        with pytest.raises(SystemExit):
            cli.main(["sessions", "revoke", "no-such-session"])


class TestChangingAPin:
    def test_the_old_pin_stops_working(self, db, pin) -> None:
        pin("4821")
        cli.main(["users", "add", "--name", "Ah Lian", "--phone", "0123"])

        pin("7788")
        cli.main(["users", "pin", "--phone", "0123"])

        with db() as session:
            stored = session.scalars(select(User)).one().pin_hash
            assert verify_pin("7788", stored)
            assert not verify_pin("4821", stored)

"""Managing the people who use the system. SPEC.md §11 Phase 5, §12.

Two things carry the weight here.

A **PIN is never stored, returned or logged**, and a weak one is refused before
anything is written — so a refused PIN leaves no half-made user behind for
somebody to "fix" later by setting one.

And **deactivating is not deleting**. The row stays, because their quotes and
payments still name them and an audit log that cannot say who did something is
not an audit log. What goes is access: §12 makes sessions never expire, so
without revocation the handset in a leaver's pocket works forever.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.security import WeakPin, verify_pin
from app.models.db import Base, DeviceSession, User
from app.services.auth import authenticate, issue_session, resolve_token
from app.services.people import (
    BadRole,
    NoSuchUser,
    PhoneTaken,
    add_person,
    deactivate,
    list_people,
    reactivate,
    set_pin,
)
from tests.helpers import assert_pin_is_not_recoverable


@pytest.fixture
def db() -> Iterator[sessionmaker[Session]]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False)
    engine.dispose()


class TestAddingSomebody:
    def test_they_can_sign_in_afterwards(self, db) -> None:
        with db() as session:
            add_person(session, name="Ah Lian", phone="0123", pin="4821")
            session.commit()

            user = authenticate(session, phone="0123", pin="4821")
            assert user.name == "Ah Lian"

    def test_the_pin_is_hashed_and_never_kept(self, db) -> None:
        with db() as session:
            user = add_person(session, name="Boss", phone="0123", pin="4821")
            session.commit()

            assert_pin_is_not_recoverable(user.pin_hash, "4821")

            # And no *other* column carries it either. Safe to scan as a
            # substring, because everything left is a name, a phone and a role
            # rather than 190 characters of random hex.
            row = dict(user.__dict__)
            row.pop("pin_hash")
            assert "4821" not in repr(row)

    def test_the_default_role_is_the_least_privileged(self, db) -> None:
        # Guessing wrong in this direction means somebody has to ask for
        # access. The other direction means somebody has it and nobody knows.
        with db() as session:
            user = add_person(session, name="Helper", phone="0123", pin="4821")
            assert user.role == "parttime"

    def test_a_weak_pin_is_refused_and_nothing_is_written(self, db) -> None:
        with db() as session:
            with pytest.raises(WeakPin):
                add_person(session, name="Boss", phone="0123", pin="0000")
            session.commit()
            assert session.scalars(select(User)).all() == []

    def test_a_duplicate_phone_is_refused(self, db) -> None:
        # The phone is the login identifier. Two people sharing one is two
        # people who cannot both sign in, and an audit trail that cannot tell
        # them apart.
        with db() as session:
            add_person(session, name="Boss", phone="0123", pin="4821")
            session.commit()
            with pytest.raises(PhoneTaken):
                add_person(session, name="Someone Else", phone="0123", pin="7788")
            session.commit()
            assert len(session.scalars(select(User)).all()) == 1

    def test_an_unknown_role_is_refused_rather_than_defaulted(self, db) -> None:
        # Defaulting here would quietly create somebody with less access than
        # intended, which somebody then works around by sharing a login.
        with db() as session, pytest.raises(BadRole):
            add_person(session, name="Boss", phone="0123", pin="4821", role="owner")

    def test_a_refused_duplicate_does_not_disturb_the_first(self, db) -> None:
        with db() as session:
            first = add_person(session, name="Boss", phone="0123", pin="4821")
            session.commit()
            with pytest.raises(PhoneTaken):
                add_person(session, name="Impostor", phone="0123", pin="7788")
            session.rollback()

            still = session.get(User, first.id)
            assert still.name == "Boss"
            assert verify_pin("4821", still.pin_hash)


class TestChangingAPin:
    def test_the_old_one_stops_working(self, db) -> None:
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            session.commit()

            set_pin(session, user.id, "7788")
            session.commit()

            fresh = session.get(User, user.id)
            assert verify_pin("7788", fresh.pin_hash)
            assert not verify_pin("4821", fresh.pin_hash)

    def test_a_weak_replacement_is_refused(self, db) -> None:
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            session.commit()

            with pytest.raises(WeakPin):
                set_pin(session, user.id, "1111")
            session.rollback()
            assert verify_pin("4821", session.get(User, user.id).pin_hash)

    def test_an_unknown_user_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchUser):
            set_pin(session, str(uuid.uuid4()), "4821")


class TestLeavers:
    def test_the_row_stays(self, db) -> None:
        # Their quotes and payments still name them. An audit log that cannot
        # say who did something is not an audit log.
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            session.commit()

            deactivate(session, user.id)
            session.commit()

            fresh = session.get(User, user.id)
            assert fresh is not None
            assert fresh.name == "Ah Lian"
            assert fresh.is_active is False
            assert fresh.deactivated_at is not None

    def test_every_live_session_is_revoked(self, db) -> None:
        # §12: sessions never expire, so revocation is the only control. The
        # handset in a leaver's pocket works forever without this.
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            first, _ = issue_session(session, user=user, device_id="d1")
            second, _ = issue_session(session, user=user, device_id="d2")
            session.commit()

            _, killed = deactivate(session, user.id)
            session.commit()

            assert killed == 2
            assert resolve_token(session, first) is None
            assert resolve_token(session, second) is None

    def test_somebody_else_s_sessions_are_untouched(self, db) -> None:
        with db() as session:
            leaver = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            stays = add_person(session, name="Boss", phone="0999", pin="7788")
            keep, _ = issue_session(session, user=stays, device_id="d9")
            session.commit()

            deactivate(session, leaver.id)
            session.commit()
            assert resolve_token(session, keep) is not None

    def test_they_still_appear_in_the_list(self, db) -> None:
        # A screen that hides leavers cannot answer "who used to have access",
        # which is the question somebody asks after something goes missing.
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            deactivate(session, user.id)
            session.commit()

            names = [p.name for p in list_people(session)]
            assert names == ["Ah Lian"]

    def test_deactivating_twice_is_harmless(self, db) -> None:
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            issue_session(session, user=user, device_id="d1")
            session.commit()

            _, first = deactivate(session, user.id)
            _, second = deactivate(session, user.id)
            session.commit()

            assert (first, second) == (1, 0)
            assert session.get(User, user.id).is_active is False

    def test_an_unknown_user_is_an_error(self, db) -> None:
        with db() as session, pytest.raises(NoSuchUser):
            deactivate(session, str(uuid.uuid4()))


class TestComingBack:
    def test_they_can_sign_in_again(self, db) -> None:
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            deactivate(session, user.id)
            session.commit()

            reactivate(session, user.id)
            session.commit()

            fresh = session.get(User, user.id)
            assert fresh.is_active is True
            assert fresh.deactivated_at is None

    def test_the_old_sessions_stay_dead(self, db) -> None:
        # Coming back means signing in again, which is the honest reading of
        # what deactivation did — and a handset that was out of somebody's
        # hands does not silently start working again.
        with db() as session:
            user = add_person(session, name="Ah Lian", phone="0123", pin="4821")
            token, _ = issue_session(session, user=user, device_id="d1")
            session.commit()

            deactivate(session, user.id)
            reactivate(session, user.id)
            session.commit()

            assert resolve_token(session, token) is None
            assert session.scalars(select(DeviceSession)).one().revoked_at is not None

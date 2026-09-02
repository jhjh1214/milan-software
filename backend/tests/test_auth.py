"""Sessions, and the rules that make them safe to never expire.

The offline constraint drives all of this. SPEC.md §12: "Indefinite. No token
expiry that locks a user out." CLAUDE.md rule 9: offline is the default, not a
fallback. So the tests that matter here are the ones that prove the
compensating controls are real -- revocation, the ledger, the throttle -- not
the happy path.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.core.security import hash_pin
from app.models.db import Base, DeviceSession, LoginAttempt, User
from app.services.auth import (
    FREE_ATTEMPTS,
    AuthenticationFailed,
    TooManyAttempts,
    authenticate,
    issue_session,
    required_backoff,
    resolve_token,
    revoke_session,
)

T0 = datetime(2026, 8, 15, 2, 0, tzinfo=UTC)


@pytest.fixture
def session() -> Iterator[Session]:
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as s:
        yield s


def a_user(
    session: Session,
    *,
    phone: str = "0123456789",
    pin: str = "4821",
    role: str = "parttime",
    active: bool = True,
) -> User:
    user = User(
        id=str(uuid.uuid4()),
        name="Ah Lian",
        phone=phone,
        role=role,
        pin_hash=hash_pin(pin),
        is_active=active,
    )
    session.add(user)
    session.flush()
    return user


class TestSigningIn:
    def test_the_right_pin_returns_the_user(self, session: Session) -> None:
        user = a_user(session)
        assert (
            authenticate(session, phone="0123456789", pin="4821", now=T0).id == user.id
        )

    def test_the_wrong_pin_is_refused(self, session: Session) -> None:
        a_user(session)
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone="0123456789", pin="9999", now=T0)

    def test_an_unknown_phone_is_refused_the_same_way(self, session: Session) -> None:
        # Same exception as a wrong PIN. A different one would tell an attacker
        # which phone numbers belong to staff.
        a_user(session)
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone="0100000000", pin="4821", now=T0)

    def test_a_deactivated_user_cannot_sign_in(self, session: Session) -> None:
        # Leavers are deactivated, never deleted -- their quotes still name
        # them -- so this is the check that actually removes their access.
        a_user(session, active=False)
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone="0123456789", pin="4821", now=T0)

    def test_a_user_with_no_pin_set_cannot_sign_in(self, session: Session) -> None:
        session.add(
            User(
                id=str(uuid.uuid4()), name="New Hire", phone="0111111111", role="staff"
            )
        )
        session.flush()
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone="0111111111", pin="", now=T0)


class TestTheAttemptLedger:
    def test_a_success_is_written_down(self, session: Session) -> None:
        a_user(session)
        authenticate(session, phone="0123456789", pin="4821", device_id="d1", now=T0)

        attempt = session.scalars(select(LoginAttempt)).one()
        assert attempt.succeeded is True
        assert attempt.device_id == "d1"

    def test_a_failure_is_written_down_too(self, session: Session) -> None:
        a_user(session)
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone="0123456789", pin="0001", now=T0)

        assert session.scalars(select(LoginAttempt)).one().succeeded is False

    def test_an_attempt_on_an_unknown_phone_is_still_recorded(
        self, session: Session
    ) -> None:
        # Someone working through a list of numbers is exactly the pattern this
        # table exists to make visible.
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone="0199999999", pin="1234", now=T0)

        attempt = session.scalars(select(LoginAttempt)).one()
        assert attempt.phone == "0199999999"
        assert attempt.user_id is None


def burn_the_free_attempts(session: Session, phone: str, at: datetime = T0) -> None:
    """Uses up every try the throttle gives away, all at the same instant."""
    for _ in range(FREE_ATTEMPTS):
        with pytest.raises(AuthenticationFailed):
            authenticate(session, phone=phone, pin="0001", now=at)


class TestThrottling:
    def test_the_first_few_tries_are_not_delayed(self, session: Session) -> None:
        # A PIN typed wrong on a phone in the sun must not cost anyone a
        # customer. Every one of these is a plain rejection, not a wait.
        a_user(session)
        burn_the_free_attempts(session, "0123456789")

    def test_the_next_failure_starts_backing_off(self, session: Session) -> None:
        a_user(session)
        burn_the_free_attempts(session, "0123456789")

        with pytest.raises(TooManyAttempts) as caught:
            authenticate(session, phone="0123456789", pin="0001", now=T0)
        assert caught.value.retry_after_seconds >= 1

    def test_the_backoff_grows(self) -> None:
        assert required_backoff(FREE_ATTEMPTS) < required_backoff(FREE_ATTEMPTS + 3)

    def test_the_backoff_is_capped_rather_than_a_lockout(self) -> None:
        # SPEC.md §12. A locked account at a fair is a person who cannot take
        # deposits, which costs more than the attack does. 500 failures is what
        # a real attack looks like, and it must still be a 60-second wait.
        assert required_backoff(500) <= timedelta(seconds=60)

    def test_the_throttle_blocks_the_right_pin_too(self, session: Session) -> None:
        # Otherwise it is not a throttle: an attacker's winning guess would
        # sail through the moment it was correct.
        a_user(session)
        burn_the_free_attempts(session, "0123456789")

        with pytest.raises(TooManyAttempts):
            authenticate(session, phone="0123456789", pin="4821", now=T0)

    def test_waiting_it_out_lets_the_right_pin_through(self, session: Session) -> None:
        a_user(session)
        burn_the_free_attempts(session, "0123456789")

        later = T0 + timedelta(minutes=2)
        assert authenticate(session, phone="0123456789", pin="4821", now=later)

    def test_the_window_is_not_forever(self, session: Session) -> None:
        # Yesterday's failures must not make today's first try wait.
        a_user(session)
        burn_the_free_attempts(session, "0123456789")

        tomorrow = T0 + timedelta(days=1)
        assert authenticate(session, phone="0123456789", pin="4821", now=tomorrow)

    def test_one_phone_being_attacked_does_not_delay_another(
        self, session: Session
    ) -> None:
        # Otherwise anyone could stop the whole team signing in at the fair by
        # guessing at one number.
        a_user(session, phone="0123456789", pin="4821")
        a_user(session, phone="0187654321", pin="7788")
        burn_the_free_attempts(session, "0123456789")

        assert authenticate(session, phone="0187654321", pin="7788", now=T0)


class TestSessions:
    def test_a_token_resolves_to_its_user(self, session: Session) -> None:
        user = a_user(session)
        token, _ = issue_session(session, user=user, device_id="d1", now=T0)

        resolved = resolve_token(session, token, now=T0)
        assert resolved is not None
        assert resolved[0].id == user.id

    def test_the_token_itself_is_never_stored(self, session: Session) -> None:
        user = a_user(session)
        token, row = issue_session(session, user=user, device_id="d1", now=T0)
        assert token != row.token_hash
        assert token not in row.token_hash

    def test_a_made_up_token_resolves_to_nothing(self, session: Session) -> None:
        a_user(session)
        assert resolve_token(session, "not-a-real-token", now=T0) is None
        assert resolve_token(session, "", now=T0) is None

    def test_a_session_does_not_expire(self, session: Session) -> None:
        # The whole point. A token that expires does so mid-fair, with no
        # signal, holding a customer's deposit.
        user = a_user(session)
        token, _ = issue_session(session, user=user, device_id="d1", now=T0)

        in_a_year = T0 + timedelta(days=365)
        assert resolve_token(session, token, now=in_a_year) is not None

    def test_revoking_ends_it_immediately(self, session: Session) -> None:
        # Revocation is the control that replaces expiry, so it has to bite.
        user = a_user(session)
        token, row = issue_session(session, user=user, device_id="d1", now=T0)
        revoke_session(session, device_session=row, reason="phone lost", now=T0)

        assert resolve_token(session, token, now=T0) is None

    def test_a_revoked_session_is_kept_not_deleted(self, session: Session) -> None:
        user = a_user(session)
        _, row = issue_session(session, user=user, device_id="d1", now=T0)
        revoke_session(session, device_session=row, reason="phone lost", now=T0)

        kept = session.scalars(select(DeviceSession)).one()
        assert kept.revoked_at is not None
        assert kept.revoked_reason == "phone lost"

    def test_signing_in_again_on_a_device_revokes_the_old_session(
        self, session: Session
    ) -> None:
        # One device, one live token, so revoking a lost handset is one act
        # rather than a hunt through history.
        user = a_user(session)
        first, _ = issue_session(session, user=user, device_id="d1", now=T0)
        second, _ = issue_session(session, user=user, device_id="d1", now=T0)

        assert resolve_token(session, first, now=T0) is None
        assert resolve_token(session, second, now=T0) is not None

    def test_signing_in_on_a_second_device_leaves_the_first_alone(
        self, session: Session
    ) -> None:
        # Two handsets at one fair is the normal case, not an anomaly.
        user = a_user(session)
        first, _ = issue_session(session, user=user, device_id="d1", now=T0)
        second, _ = issue_session(session, user=user, device_id="d2", now=T0)

        assert resolve_token(session, first, now=T0) is not None
        assert resolve_token(session, second, now=T0) is not None

    def test_deactivating_a_user_kills_their_live_sessions(
        self, session: Session
    ) -> None:
        # Otherwise a leaver keeps quoting from a handset nobody collected.
        user = a_user(session)
        token, _ = issue_session(session, user=user, device_id="d1", now=T0)

        user.is_active = False
        session.flush()

        assert resolve_token(session, token, now=T0) is None

    def test_last_seen_tracks_use(self, session: Session) -> None:
        user = a_user(session)
        token, row = issue_session(session, user=user, device_id="d1", now=T0)

        later = T0 + timedelta(hours=6)
        resolve_token(session, token, now=later)
        assert row.last_seen_at == later

"""Who is asking, and what they are allowed to do.

Shaped by one constraint that overrides the usual advice (SPEC.md §12, CLAUDE.md
rule 9): **offline is the default, not a fallback, and no token expiry may lock
a user out mid-fair.** So sessions do not expire. A part-timer signs in once,
before the fair, and the handset keeps working for four days with no signal and
no refresh call it cannot make.

That trades away the thing expiry buys -- a stolen token going stale on its own
-- so the compensating controls are: the token is 256 random bits and only its
SHA-256 is stored; every session is a named row that an admin can revoke; and
every login attempt, successful or not, is written to an append-only ledger.

PURE of HTTP. The router calls this; the tests call it directly.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.security import (
    new_token,
    token_fingerprint,
    verify_pin,
)
from ..models.db import DeviceSession, LoginAttempt, User

#: How far back the throttle looks.
ATTEMPT_WINDOW = timedelta(minutes=15)
#: Free tries before the delay starts. Someone fat-fingering a PIN on a phone
#: in the sun gets several goes without noticing anything.
FREE_ATTEMPTS = 5
#: The delay never grows past this. It is a speed bump, not a lockout: a locked
#: account at a fair is a person who cannot take deposits.
MAX_BACKOFF = timedelta(seconds=60)


class AuthenticationFailed(Exception):
    """Wrong PIN, unknown phone, or a deactivated user.

    One exception for all three on purpose: distinguishing them tells an
    attacker which phone numbers are staff.
    """


class TooManyAttempts(Exception):
    """Backing off. Carries the seconds to wait so the app can say so."""

    def __init__(self, retry_after_seconds: int) -> None:
        super().__init__(f"try again in {retry_after_seconds}s")
        self.retry_after_seconds = retry_after_seconds


def _now(now: datetime | None) -> datetime:
    return now or datetime.now(UTC)


def _recent_failures(session: Session, phone: str, at: datetime) -> list[LoginAttempt]:
    return list(
        session.scalars(
            select(LoginAttempt)
            .where(
                LoginAttempt.phone == phone,
                LoginAttempt.succeeded.is_(False),
                LoginAttempt.at >= at - ATTEMPT_WINDOW,
            )
            .order_by(LoginAttempt.at.desc())
        )
    )


def required_backoff(failures: int) -> timedelta:
    """Doubling, from one second, capped. Zero for the first few tries.

    The exponent is clamped before it is used: ``2 ** 495`` seconds is not a
    number ``timedelta`` will accept, and a determined attacker is exactly the
    person who gets the count that high.
    """
    if failures < FREE_ATTEMPTS:
        return timedelta(0)
    exponent = min(failures - FREE_ATTEMPTS, 16)
    return min(MAX_BACKOFF, timedelta(seconds=2**exponent))


def _record(
    session: Session,
    *,
    phone: str,
    user_id: str | None,
    device_id: str | None,
    succeeded: bool,
    at: datetime,
) -> None:
    session.add(
        LoginAttempt(
            id=str(uuid.uuid4()),
            phone=phone,
            user_id=user_id,
            device_id=device_id,
            succeeded=succeeded,
            at=at,
        )
    )
    session.flush()


def authenticate(
    session: Session,
    *,
    phone: str,
    pin: str,
    device_id: str | None = None,
    now: datetime | None = None,
) -> User:
    """Checks a PIN, writing the attempt down either way.

    Raises ``TooManyAttempts`` before it checks anything, so a caller under
    backoff does not even get the timing signal of a hash running.
    """
    at = _now(now)

    failures = _recent_failures(session, phone, at)
    if failures:
        wait = required_backoff(len(failures))
        elapsed = at - _as_utc(failures[0].at)
        if elapsed < wait:
            raise TooManyAttempts(int((wait - elapsed).total_seconds()) + 1)

    user = session.scalars(select(User).where(User.phone == phone)).first()

    # The PIN is verified even when the user is missing or deactivated, so the
    # response takes the same time either way. Skipping the hash for an unknown
    # phone is a timing oracle for which numbers are staff.
    ok = verify_pin(pin, user.pin_hash if user else None)
    if user is None or not user.is_active or not ok:
        _record(
            session,
            phone=phone,
            user_id=user.id if user else None,
            device_id=device_id,
            succeeded=False,
            at=at,
        )
        raise AuthenticationFailed("phone or PIN is wrong")

    _record(
        session,
        phone=phone,
        user_id=user.id,
        device_id=device_id,
        succeeded=True,
        at=at,
    )
    return user


def issue_session(
    session: Session,
    *,
    user: User,
    device_id: str,
    device_label: str | None = None,
    now: datetime | None = None,
) -> tuple[str, DeviceSession]:
    """Mints a token for one handset.

    Returns the token **once**. Only its fingerprint is stored, so it cannot be
    read back out of the database and a lost one is re-issued, never recovered.

    Signing in again on the same handset revokes the previous session for it:
    one device, one live token, so revoking a lost phone is a single act.
    """
    at = _now(now)

    for previous in session.scalars(
        select(DeviceSession).where(
            DeviceSession.device_id == device_id,
            DeviceSession.revoked_at.is_(None),
        )
    ):
        previous.revoked_at = at
        previous.revoked_reason = "superseded by a new sign-in on this device"

    token = new_token()
    row = DeviceSession(
        id=str(uuid.uuid4()),
        user_id=user.id,
        device_id=device_id,
        device_label=device_label,
        token_hash=token_fingerprint(token),
        last_seen_at=at,
    )
    session.add(row)
    session.flush()
    return token, row


def resolve_token(
    session: Session, token: str, *, now: datetime | None = None
) -> tuple[User, DeviceSession] | None:
    """The user behind a token, or None.

    None -- not an exception -- because "no such token" and "revoked" and "the
    user has left" are all the same answer to the caller: 401.
    """
    if not token:
        return None

    row = session.scalars(
        select(DeviceSession).where(
            DeviceSession.token_hash == token_fingerprint(token)
        )
    ).first()
    if row is None or row.revoked_at is not None:
        return None

    user = session.get(User, row.user_id)
    if user is None or not user.is_active:
        return None

    # Not for expiry -- nothing here expires. It is so an admin looking at the
    # session list can tell a handset in a drawer from one in use.
    row.last_seen_at = _now(now)
    return user, row


def revoke_session(
    session: Session,
    *,
    device_session: DeviceSession,
    reason: str,
    now: datetime | None = None,
) -> None:
    """Ends one session. The row stays: it is who was signed in, and when."""
    device_session.revoked_at = _now(now)
    device_session.revoked_reason = reason
    session.flush()


def _as_utc(value: datetime) -> datetime:
    """SQLite hands back naive datetimes; Postgres does not.

    Comparing the two raises, and it would raise inside the login path, on the
    branch that only runs after somebody has already failed a few times -- so it
    would be found by a user, not by a test, unless it is handled here.
    """
    return value if value.tzinfo else value.replace(tzinfo=UTC)

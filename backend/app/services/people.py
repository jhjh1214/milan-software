"""Managing the people who use the system. SPEC.md §11 Phase 5, §12.

    Users and roles — individual PINs, deactivate leavers

## What this does not change about the bootstrap

`deploy/README.md` says creating a user needs shell access to the box, and that
is still true of the **first** one: there is no register endpoint, no bootstrap
password in the image, and nothing here can be reached without an admin session
that somebody had to be given at a terminal.

What these do is let an admin who is already signed in add the next person
without one. That lowers no bar — you needed admin to do it either way — and it
raises a real one, because the alternative is the boss keeping one shared login
that reaches every handset, which §6.5 already says happens within a month.

## Deactivating is not deleting

The row stays. Their quotes, payments and overrides still name them, and an
audit log that cannot say who did something is not an audit log. What goes is
their access: every live session is revoked, so the handset in their pocket
stops working the next time it reaches the server.

Pure of HTTP. The router calls this; the tests call it directly.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.security import WeakPin, hash_pin
from ..models.db import DeviceSession, User

#: The roles SPEC.md §3 names, least privileged first. `parttime` is the
#: default everywhere, because the failure of guessing wrong in that direction
#: is somebody having to ask for access rather than somebody having it.
ROLES = ("parttime", "staff", "admin")


class PhoneTaken(ValueError):
    """Somebody already signs in with that number.

    The phone is the login identifier, so two people sharing one is two people
    who cannot both sign in -- and worse, an audit trail that cannot tell them
    apart.
    """


class NoSuchUser(LookupError):
    pass


class BadRole(ValueError):
    pass


def list_people(session: Session) -> list[User]:
    """Everybody, including leavers.

    Leavers are included on purpose. A screen that hides them cannot answer
    "who used to have access", which is the question somebody asks after
    something goes missing.
    """
    return list(session.scalars(select(User).order_by(User.name)))


def add_person(
    session: Session,
    *,
    name: str,
    phone: str,
    pin: str,
    role: str = "parttime",
    email: str | None = None,
    language: str = "zh",
) -> User:
    """Creates somebody who can sign in.

    The PIN is hashed here and never stored, logged or returned. It is checked
    for strength first: `hash_pin` raises `WeakPin` rather than accepting
    `0000`, and nothing catches that on the way past.
    """
    if role not in ROLES:
        raise BadRole(f'"{role}" is not a role: {", ".join(ROLES)}')

    if session.scalars(select(User).where(User.phone == phone)).first() is not None:
        raise PhoneTaken(f"{phone} already belongs to someone")

    # Raises WeakPin before anything is written, so a refused PIN leaves no
    # half-made user behind.
    pin_hash = hash_pin(pin)

    user = User(
        id=str(uuid.uuid4()),
        name=name,
        phone=phone,
        email=email,
        role=role,
        pin_hash=pin_hash,
        language=language,
    )
    session.add(user)
    session.flush()
    return user


def set_pin(session: Session, user_id: str, pin: str) -> User:
    """Changes somebody's PIN. The old one stops working immediately."""
    user = session.get(User, user_id)
    if user is None:
        raise NoSuchUser(user_id)

    user.pin_hash = hash_pin(pin)
    session.flush()
    return user


def set_language(session: Session, user_id: str, language: str) -> User:
    """A person's own choice, and it follows their account everywhere.

    Self-service, unlike everything else in this file: SPEC.md §13 C9 says
    the language is switchable per user, not per device, and a person does
    not need an admin's permission to read this system in their own language.
    """
    user = session.get(User, user_id)
    if user is None:
        raise NoSuchUser(user_id)

    user.language = language
    session.flush()
    return user


def deactivate(session: Session, user_id: str) -> tuple[User, int]:
    """Ends somebody's access, and returns how many sessions that killed.

    Never deletes. Their quotes and payments still name them, and §12 makes
    revocation the control rather than expiry -- sessions never expire, so
    without this the handset in a leaver's pocket keeps working forever.
    """
    user = session.get(User, user_id)
    if user is None:
        raise NoSuchUser(user_id)

    user.is_active = False
    user.deactivated_at = datetime.now(UTC)

    killed = 0
    for row in session.scalars(
        select(DeviceSession).where(
            DeviceSession.user_id == user.id,
            DeviceSession.revoked_at.is_(None),
        )
    ):
        row.revoked_at = datetime.now(UTC)
        row.revoked_reason = f"{user.name} deactivated"
        killed += 1

    session.flush()
    return user, killed


def reactivate(session: Session, user_id: str) -> User:
    """Lets somebody back in.

    Their old sessions stay revoked. Coming back means signing in again, which
    is the honest reading of what deactivation did -- and it means a handset
    that was out of somebody's hands does not silently start working again.
    """
    user = session.get(User, user_id)
    if user is None:
        raise NoSuchUser(user_id)

    user.is_active = True
    user.deactivated_at = None
    session.flush()
    return user


__all__ = [
    "ROLES",
    "BadRole",
    "NoSuchUser",
    "PhoneTaken",
    "WeakPin",
    "add_person",
    "deactivate",
    "list_people",
    "reactivate",
    "set_pin",
]

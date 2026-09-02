"""Operator commands. The only way to make the first admin.

    docker compose exec -T api python -m app.cli users add \
        --name "Boss" --phone 0123456789 --role admin

Everything here is deliberately server-side. There is no "register" endpoint and
no bootstrap password baked into an image: creating a user requires shell access
to the box, which is exactly the bar it should have.

**PINs are never taken from the command line.** An argument lands in shell
history and in ``ps`` output for every other process on the machine, so a PIN is
read from the terminal, or from stdin when there is no terminal.
"""

from __future__ import annotations

import argparse
import getpass
import json
import sys
import uuid
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import select

from .core.security import WeakPin, hash_pin
from .db import session_scope
from .models.db import DeviceSession, User
from .services.ingest import active_card, publish_card

ROLES = ("admin", "staff", "parttime")


def read_pin(confirm: bool = True) -> str:
    """From the terminal if there is one, else from stdin (for scripts)."""
    if not sys.stdin.isatty():
        return sys.stdin.readline().strip()

    pin = getpass.getpass("PIN: ")
    if confirm and getpass.getpass("PIN again: ") != pin:
        raise SystemExit("the two PINs do not match")
    return pin


def cmd_user_add(args: argparse.Namespace) -> int:
    pin = read_pin()
    try:
        pin_hash = hash_pin(pin)
    except WeakPin as exc:
        raise SystemExit(f"refused: {exc}") from exc

    with session_scope() as session:
        if session.scalars(select(User).where(User.phone == args.phone)).first():
            raise SystemExit(f"{args.phone} already belongs to someone")

        user = User(
            id=str(uuid.uuid4()),
            name=args.name,
            phone=args.phone,
            email=args.email,
            role=args.role,
            pin_hash=pin_hash,
            language=args.language,
        )
        session.add(user)
        print(f"created {user.name} ({user.role}) {user.id}")
    return 0


def cmd_user_pin(args: argparse.Namespace) -> int:
    pin = read_pin()
    try:
        pin_hash = hash_pin(pin)
    except WeakPin as exc:
        raise SystemExit(f"refused: {exc}") from exc

    with session_scope() as session:
        user = session.scalars(select(User).where(User.phone == args.phone)).first()
        if user is None:
            raise SystemExit(f"no user with phone {args.phone}")
        user.pin_hash = pin_hash
        print(f"PIN changed for {user.name}")
    return 0


def cmd_user_list(_: argparse.Namespace) -> int:
    with session_scope() as session:
        for user in session.scalars(select(User).order_by(User.name)):
            state = "active" if user.is_active else "INACTIVE"
            pin = "pin set" if user.pin_hash else "NO PIN"
            print(
                f"{user.name:<20} {user.role:<9} {user.phone or '-':<14} {state}, {pin}"
            )
    return 0


def cmd_user_deactivate(args: argparse.Namespace) -> int:
    """Deactivates, never deletes. Their quotes and payments still name them."""
    with session_scope() as session:
        user = session.scalars(select(User).where(User.phone == args.phone)).first()
        if user is None:
            raise SystemExit(f"no user with phone {args.phone}")

        user.is_active = False
        user.deactivated_at = datetime.now(UTC)

        # Their live handsets go with them. Otherwise a leaver keeps quoting
        # from a phone nobody collected.
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

        print(f"{user.name} deactivated, {killed} session(s) revoked")
    return 0


def cmd_sessions_list(_: argparse.Namespace) -> int:
    with session_scope() as session:
        rows = session.scalars(
            select(DeviceSession).order_by(DeviceSession.created_at.desc())
        )
        for row in rows:
            user = session.get(User, row.user_id)
            state = "revoked" if row.revoked_at else "live"
            seen = row.last_seen_at.isoformat() if row.last_seen_at else "never"
            print(
                f"{row.id}  {user.name if user else '?':<20} "
                f"{row.device_label or row.device_id:<24} {state:<8} last seen {seen}"
            )
    return 0


def cmd_sessions_revoke(args: argparse.Namespace) -> int:
    with session_scope() as session:
        row = session.get(DeviceSession, args.session_id)
        if row is None:
            raise SystemExit(f"no session {args.session_id}")
        if row.revoked_at is not None:
            print("already revoked")
            return 0
        row.revoked_at = datetime.now(UTC)
        row.revoked_reason = args.reason
        print(f"revoked {row.id}")
    return 0


def cmd_card_publish(args: argparse.Namespace) -> int:
    """Publishes a price list from a file.

    The API route is the normal path; this exists for the first publish on a
    new box, before anyone has an admin handset.
    """
    payload = json.loads(Path(args.file).read_text(encoding="utf-8"))
    if "version" not in payload:
        raise SystemExit("the card has no version")

    with session_scope() as session:
        live = active_card(session, args.list_id)
        if live is not None and payload["version"] <= live.version:
            raise SystemExit(
                f"version {payload['version']} is not newer than the active "
                f"{live.version}. Versions only go up."
            )
        row = publish_card(
            session,
            list_id=args.list_id,
            payload=payload,
            published_by=args.by,
        )
        print(f"published {row.list_id} version {row.version}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="app.cli", description=__doc__)
    top = parser.add_subparsers(dest="group", required=True)

    users = top.add_parser("users").add_subparsers(dest="action", required=True)

    add = users.add_parser("add", help="create a user (prompts for the PIN)")
    add.add_argument("--name", required=True)
    add.add_argument("--phone", required=True)
    add.add_argument("--email")
    add.add_argument("--role", choices=ROLES, default="parttime")
    add.add_argument("--language", choices=("zh", "en", "ms"), default="zh")
    add.set_defaults(func=cmd_user_add)

    pin = users.add_parser("pin", help="set someone's PIN")
    pin.add_argument("--phone", required=True)
    pin.set_defaults(func=cmd_user_pin)

    users.add_parser("list").set_defaults(func=cmd_user_list)

    off = users.add_parser("deactivate", help="a leaver: keeps the row, kills access")
    off.add_argument("--phone", required=True)
    off.set_defaults(func=cmd_user_deactivate)

    sessions = top.add_parser("sessions").add_subparsers(dest="action", required=True)
    sessions.add_parser("list").set_defaults(func=cmd_sessions_list)

    revoke = sessions.add_parser("revoke", help="a lost or stolen handset")
    revoke.add_argument("session_id")
    revoke.add_argument("--reason", default="revoked by an operator")
    revoke.set_defaults(func=cmd_sessions_revoke)

    cards = top.add_parser("cards").add_subparsers(dest="action", required=True)
    pub = cards.add_parser("publish", help="publish a rate card from a JSON file")
    pub.add_argument("file")
    pub.add_argument("--list-id", choices=("fair", "standard"), required=True)
    pub.add_argument("--by", help="who to record as the publisher")
    pub.set_defaults(func=cmd_card_publish)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

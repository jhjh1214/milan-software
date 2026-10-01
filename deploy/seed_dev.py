"""Seeds a LOCAL demo environment. Dev only -- wired up by docker-compose.dev.yml
as the one-shot `seed` service; nothing in the production compose file runs it.

Idempotent: every step checks what already exists first, so running it on every
`docker compose up` is safe and a box that already has data is left alone.

Runs inside the api image (so `app.*` is importable and DATABASE_URL is set):

- users and rate cards go in through the same code the operator CLI uses --
  there is deliberately no register endpoint to call;
- the project, material and stock lot go in through the real HTTP routes,
  signed in as the admin just created, because the CLI has nothing for them.

The PINs below are demo credentials for a throwaway local database. They are
not secrets and must never be used anywhere that is reachable from outside.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from sqlalchemy import select

from app.core.security import hash_pin
from app.db import session_scope
from app.models.db import User
from app.services.ingest import active_card, publish_card

API_URL = os.environ.get("SEED_API_URL", "http://api:8000")
SHARED = Path(os.environ.get("SEED_SHARED_DIR", "/shared"))

PIN = "4821"
USERS = [
    ("Boss", "0123456789", "admin"),
    ("Staff Sam", "0123456780", "staff"),
    ("Part-timer Amy", "0123456781", "parttime"),
]
CARDS = [
    ("fair", "rate-card-fair-2026-08.json"),
    ("standard", "rate-card-standard.json"),
]


def seed_users() -> None:
    with session_scope() as session:
        for name, phone, role in USERS:
            if session.scalars(select(User).where(User.phone == phone)).first():
                print(f"user {phone} exists")
                continue
            session.add(
                User(
                    id=str(uuid.uuid4()),
                    name=name,
                    phone=phone,
                    role=role,
                    pin_hash=hash_pin(PIN),
                    language="en",
                )
            )
            print(f"user {name} ({role}) created")


def seed_cards() -> None:
    with session_scope() as session:
        for list_id, filename in CARDS:
            if active_card(session, list_id) is not None:
                print(f"{list_id} card exists")
                continue
            payload = json.loads((SHARED / filename).read_text(encoding="utf-8"))
            row = publish_card(
                session, list_id=list_id, payload=payload, published_by=None
            )
            print(f"published {row.list_id} version {row.version}")


def call(method: str, path: str, token: str | None = None, body: dict | None = None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API_URL + path, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"{method} {path} -> {exc.code}: {exc.read().decode()}")


def seed_inventory() -> None:
    token = call(
        "POST",
        "/api/auth/login",
        body={
            "phone": USERS[0][1],
            "pin": PIN,
            "device_id": "seed",
            "device_label": "seed",
        },
    )["token"]

    if not call("GET", "/api/projects", token)["projects"]:
        call(
            "POST",
            "/api/projects",
            token,
            {
                "name": "Taman Harmoni",
                "developer": "ABC Sdn Bhd",
                "area": "Ayer Keroh, Melaka",
            },
        )
        print("project created")
    else:
        print("projects exist")

    if not call("GET", "/api/materials", token)["materials"]:
        material = call(
            "POST",
            "/api/materials",
            token,
            {
                "family": "flooring",
                "variant_compat": ["spc_4mm_1mm"],
                "code": "SPC-OAK-4MM",
                "names": {
                    "zh": "四毫米SPC地板",
                    "en": "4mm SPC flooring",
                    "ms": "Lantai SPC 4mm",
                },
                "uom": "box",
                "coverage_per_unit": "18",
                "reorder_level": "20",
            },
        )
        call(
            "POST",
            "/api/stock/receive",
            token,
            {
                "material_id": material["id"],
                "lot_ref": "DYE-2609-01",
                "qty": "40",
                "cost_sen": 8500,
                "location": "Warehouse A",
            },
        )
        print("material and stock lot created")
    else:
        print("materials exist")


if __name__ == "__main__":
    seed_users()
    seed_cards()
    seed_inventory()
    print("seed complete")
    sys.exit(0)

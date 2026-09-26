"""Setting when a fair runs: the pure decision. The route is in test_api.py."""

from __future__ import annotations

import json
from collections.abc import Iterator
from datetime import date
from pathlib import Path

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.models.db import Base, FairDatesEdit
from app.pricing.fair_dates import (
    MAX_CODE_LENGTH,
    FairDates,
    FairDatesRefusal,
    decide_fair_dates,
)
from app.services.ingest import (
    FairDatesRefused,
    active_card,
    edit_fair_dates,
    publish_card,
)

AUGUST = FairDates(
    code="MITC-2026-08", valid_from=date(2026, 8, 28), valid_to=date(2026, 8, 31)
)


def decide(**over):
    args = {
        "before": AUGUST,
        "code": "MITC-2026-12",
        "valid_from": date(2026, 12, 4),
        "valid_to": date(2026, 12, 7),
        "reason": "December fair booked",
        "by_user_id": "admin-1",
    }
    args.update(over)
    return decide_fair_dates(**args)


def test_a_new_fair_is_accepted_and_names_who_and_why() -> None:
    d = decide()
    assert d.is_applied
    assert d.record is not None
    assert d.record.before == AUGUST
    assert d.record.after == FairDates(
        code="MITC-2026-12",
        valid_from=date(2026, 12, 4),
        valid_to=date(2026, 12, 7),
    )
    assert d.record.by_user_id == "admin-1"


def test_a_first_window_on_a_card_with_none_is_accepted() -> None:
    assert decide(before=None).is_applied


def test_a_one_day_fair_is_fine() -> None:
    d = decide(valid_from=date(2026, 12, 4), valid_to=date(2026, 12, 4))
    assert d.is_applied


def test_ending_before_it_starts_is_refused() -> None:
    d = decide(valid_from=date(2026, 12, 7), valid_to=date(2026, 12, 6))
    assert d.refused_because is FairDatesRefusal.ENDS_BEFORE_IT_STARTS


def test_a_missing_or_trivial_reason_is_refused() -> None:
    for reason in (None, "", "   ", "abc", "  ab  "):
        assert decide(reason=reason).refused_because is FairDatesRefusal.NO_REASON


def test_the_reason_is_stored_trimmed() -> None:
    d = decide(reason="  moved a week  ")
    assert d.record is not None and d.record.reason == "moved a week"


def test_an_empty_or_overlong_code_is_refused() -> None:
    assert decide(code="   ").refused_because is FairDatesRefusal.BAD_CODE
    too_long = "X" * (MAX_CODE_LENGTH + 1)
    assert decide(code=too_long).refused_because is FairDatesRefusal.BAD_CODE
    assert decide(code="X" * MAX_CODE_LENGTH).is_applied


def test_the_code_is_stored_trimmed() -> None:
    d = decide(code="  MITC-2026-12 ")
    assert d.record is not None and d.record.after.code == "MITC-2026-12"


def test_changing_nothing_is_refused() -> None:
    d = decide(
        code=" MITC-2026-08",
        valid_from=AUGUST.valid_from,
        valid_to=AUGUST.valid_to,
    )
    assert d.refused_because is FairDatesRefusal.NO_CHANGE


def test_moving_only_the_end_is_a_change() -> None:
    d = decide(
        code=AUGUST.code, valid_from=AUGUST.valid_from, valid_to=date(2026, 9, 1)
    )
    assert d.is_applied


# --- The service: a new card version, and the audit row -----------------

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)
STANDARD = json.loads(
    (ROOT / "shared" / "rate-card-standard.json").read_text(encoding="utf-8")
)


@pytest.fixture
def session() -> Iterator[Session]:
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as s:
        publish_card(s, list_id="fair", payload=FAIR)
        publish_card(s, list_id="standard", payload=STANDARD)
        yield s


def test_an_edit_publishes_a_new_fair_card_with_only_the_window_moved(
    session: Session,
) -> None:
    edit = edit_fair_dates(
        session,
        code="MITC-2026-12",
        valid_from=date(2026, 12, 4),
        valid_to=date(2026, 12, 7),
        reason="December fair booked",
        by_user_id="admin-1",
    )
    live = active_card(session, "fair")
    assert live is not None
    # One sequence across both lists: standard already holds 101.
    assert live.version == edit.resulting_version == 102
    promo = live.payload["promo"]
    assert (promo["code"], promo["valid_from"], promo["valid_to"]) == (
        "MITC-2026-12",
        "2026-12-04",
        "2026-12-07",
    )
    # The note travels untouched, and so does every price.
    assert promo["note"] == FAIR["promo"]["note"]
    assert live.payload["rules"] == FAIR["rules"]
    # Standard is not touched.
    standard = active_card(session, "standard")
    assert standard is not None and standard.version == 101


def test_the_audit_row_names_before_after_who_and_why(session: Session) -> None:
    edit_fair_dates(
        session,
        code="MITC-2026-12",
        valid_from=date(2026, 12, 4),
        valid_to=date(2026, 12, 7),
        reason="  December fair booked ",
        by_user_id="admin-1",
    )
    row = session.scalars(select(FairDatesEdit)).one()
    assert (row.before_code, row.before_valid_from, row.before_valid_to) == (
        "MITC-2026-08",
        date(2026, 8, 28),
        date(2026, 8, 31),
    )
    assert (row.after_code, row.after_valid_from, row.after_valid_to) == (
        "MITC-2026-12",
        date(2026, 12, 4),
        date(2026, 12, 7),
    )
    assert row.reason == "December fair booked"
    assert row.by_user_id == "admin-1"
    assert row.resulting_version == 102


def test_a_refusal_publishes_nothing_and_records_nothing(session: Session) -> None:
    with pytest.raises(FairDatesRefused):
        edit_fair_dates(
            session,
            code="MITC-2026-12",
            valid_from=date(2026, 12, 7),
            valid_to=date(2026, 12, 4),
            reason="typo'd dates",
            by_user_id="admin-1",
        )
    live = active_card(session, "fair")
    assert live is not None and live.version == 1
    assert session.scalars(select(FairDatesEdit)).all() == []

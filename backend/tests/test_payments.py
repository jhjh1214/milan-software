"""Payments and receipt numbers. §6.4, §9.2, and CLAUDE.md on IDs.

Two things must hold, and both are about a customer holding a piece of paper:

- a retry never takes the same RM300 twice
- a retry gets back the **same** receipt number, because they may already be
  holding one with that number printed on it

The Phase 4 acceptance criterion this serves: *"Two category deposits recorded
offline; both receipts resolve after sync."*
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.api.schemas import PaymentIn
from app.models.db import Base, Payment, ReceiptCounter
from app.services.ingest import publish_card, push_payment
from app.services.receipts import issue_receipt_no, period_of

ROOT = Path(__file__).resolve().parents[2]
FAIR = json.loads(
    (ROOT / "shared" / "rate-card-fair-2026-08.json").read_text(encoding="utf-8")
)

AT_THE_FAIR = datetime(2026, 8, 29, 14, 30, tzinfo=UTC)


@pytest.fixture
def session() -> Iterator[Session]:
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as s:
        publish_card(s, list_id="fair", payload=FAIR)
        s.commit()
        yield s


def a_payment(
    *,
    payment_id: str | None = None,
    amount_sen: int = 30000,
    method: str = "cash",
    kind: str = "deposit",
    taken_at: datetime | None = None,
) -> PaymentIn:
    return PaymentIn(
        id=payment_id or str(uuid.uuid4()),
        quote_id=str(uuid.uuid4()),
        kind=kind,
        amount_sen=amount_sen,
        method=method,
        taken_at=taken_at or AT_THE_FAIR,
        device_id=str(uuid.uuid4()),
    )


class TestTakingMoneyTwice:
    def test_the_same_payment_pushed_twice_is_one_row(self, session: Session) -> None:
        # The failure this prevents is the worst kind: charging a customer
        # RM600 because the connection dropped once.
        payload = a_payment()

        first = push_payment(session, payload)
        session.commit()
        second = push_payment(session, payload)
        session.commit()

        assert first.duplicate is False
        assert second.duplicate is True
        assert len(session.scalars(select(Payment)).all()) == 1

    def test_a_retry_returns_the_same_receipt_number(self, session: Session) -> None:
        # The customer may already be holding a printed receipt. A second
        # number for one payment is a second receipt for money taken once.
        payload = a_payment()

        first = push_payment(session, payload)
        session.commit()
        second = push_payment(session, payload)

        assert second.receipt_no == first.receipt_no

    def test_ten_retries_are_still_one_payment(self, session: Session) -> None:
        payload = a_payment()
        for _ in range(10):
            push_payment(session, payload)
            session.commit()

        assert len(session.scalars(select(Payment)).all()) == 1

    def test_two_different_payments_both_land(self, session: Session) -> None:
        # Idempotency must not collapse two genuine RM300s — that is exactly
        # the second category deposit §6.2 exists to collect.
        push_payment(session, a_payment())
        push_payment(session, a_payment())
        session.commit()

        assert len(session.scalars(select(Payment)).all()) == 2


class TestReceiptNumbers:
    def test_the_device_never_supplies_one(self) -> None:
        # It is not a field on the way in. CLAUDE.md: never fabricated
        # on-device, because two handsets offline at one fair would agree.
        assert "receipt_no" not in PaymentIn.model_fields

    def test_they_are_issued_in_order(self, session: Session) -> None:
        numbers = []
        for _ in range(3):
            numbers.append(push_payment(session, a_payment()).receipt_no)
            session.commit()

        assert numbers == ["R2608-0001", "R2608-0002", "R2608-0003"]

    def test_the_period_comes_from_when_it_was_taken(self, session: Session) -> None:
        # A payment taken on the last night of a fair and synced the next
        # morning belongs to the month it happened in, not the month it
        # arrived in.
        august = push_payment(
            session, a_payment(taken_at=datetime(2026, 8, 31, 23, 50, tzinfo=UTC))
        )
        session.commit()
        september = push_payment(
            session, a_payment(taken_at=datetime(2026, 9, 1, 0, 10, tzinfo=UTC))
        )
        session.commit()

        assert august.receipt_no.startswith("R2608-")
        assert september.receipt_no.startswith("R2609-")

    def test_each_month_starts_again_at_one(self, session: Session) -> None:
        push_payment(session, a_payment())
        session.commit()
        later = push_payment(
            session, a_payment(taken_at=datetime(2026, 12, 1, tzinfo=UTC))
        )
        session.commit()

        assert later.receipt_no == "R2612-0001"

    def test_a_number_belongs_to_one_payment_only(self, session: Session) -> None:
        for _ in range(5):
            push_payment(session, a_payment())
            session.commit()

        numbers = [p.receipt_no for p in session.scalars(select(Payment))]
        assert len(set(numbers)) == len(numbers)

    def test_the_counter_advances_rather_than_being_recomputed(
        self, session: Session
    ) -> None:
        # Counting existing rows would re-use a number after a deletion, and
        # rows here are never deleted precisely so that cannot be relied on.
        push_payment(session, a_payment())
        session.commit()

        counter = session.get(ReceiptCounter, period_of(AT_THE_FAIR.date()))
        assert counter is not None
        assert counter.next_value == 2

    def test_the_format_reads_as_a_month(self, session: Session) -> None:
        # R2608 has to be recognisable as August 2026 by somebody holding the
        # receipt and asking about it on the phone.
        assert issue_receipt_no(session, taken_at=AT_THE_FAIR.date()) == ("R2608-0001")

    def test_the_sequence_is_padded_so_it_sorts(self, session: Session) -> None:
        # R2608-10 would sort before R2608-2 in every list the office ever
        # pastes into a spreadsheet.
        for _ in range(9):
            issue_receipt_no(session, taken_at=AT_THE_FAIR.date())
        assert issue_receipt_no(session, taken_at=AT_THE_FAIR.date()) == ("R2608-0010")


class TestWhatIsRecorded:
    def test_the_payment_keeps_its_own_details(self, session: Session) -> None:
        payload = a_payment(amount_sen=50000, method="duitnow", kind="balance")
        push_payment(session, payload)
        session.commit()

        row = session.scalars(select(Payment)).one()
        assert row.amount_sen == 50000
        assert row.method == "duitnow"
        assert row.kind == "balance"
        assert row.receipt_no is not None

    def test_a_refund_is_a_row_of_its_own(self, session: Session) -> None:
        # Never an edit to the row it reverses.
        push_payment(session, a_payment())
        session.commit()
        push_payment(session, a_payment(kind="refund"))
        session.commit()

        kinds = sorted(p.kind for p in session.scalars(select(Payment)))
        assert kinds == ["deposit", "refund"]

    def test_a_refund_gets_its_own_receipt_number(self, session: Session) -> None:
        # The customer is handed a piece of paper for the money going back too.
        deposit = push_payment(session, a_payment())
        session.commit()
        refund = push_payment(session, a_payment(kind="refund"))
        session.commit()

        assert refund.receipt_no != deposit.receipt_no


class TestValidation:
    @pytest.mark.parametrize("amount", [0, -30000])
    def test_a_non_positive_amount_is_refused(self, amount: int) -> None:
        # A refund is negative by its kind, not by its sign, so nobody has to
        # remember which rows carry a minus.
        with pytest.raises(ValueError):
            a_payment(amount_sen=amount)

    def test_an_unknown_method_is_refused(self) -> None:
        # The cash-up totals by method. A method it does not know about would
        # silently vanish from the reconciliation.
        with pytest.raises(ValueError):
            a_payment(method="bitcoin")

    def test_an_unknown_kind_is_refused(self) -> None:
        with pytest.raises(ValueError):
            a_payment(kind="tip")

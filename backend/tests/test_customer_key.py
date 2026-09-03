"""Which customer a rate lock belongs to, against the cases the Dart suite loads.

SPEC.md §6.1 and §13 B9. If this file and
``mobile/test/pricing/customer_key_test.dart`` disagree, a lock granted on a
handset and the same lock read back from the server belong to different people —
and one of them gets the other's held prices, or loses their own.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.pricing.customer_key import (
    MIN_PHONE_DIGITS,
    CustomerKey,
    customer_key_for,
    normalise_phone,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads(
    (ROOT / "shared" / "pricing-fixtures.json").read_text(encoding="utf-8")
)
CASES = FIXTURES["customer_key_cases"]


class TestTheSharedContract:
    def test_the_contract_carries_cases_at_all(self) -> None:
        assert len(CASES) >= 10

    def test_it_covers_both_kinds_of_key(self) -> None:
        assert {c["expect"]["from_phone"] for c in CASES} == {True, False}

    @pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
    def test_the_fixtures_agree_with_the_rule(self, case: dict) -> None:
        key = customer_key_for(phone=case["phone"], quote_id=case["quote_id"])
        why = case["why"]
        assert key.value == case["expect"]["key"], why
        assert key.from_phone == case["expect"]["from_phone"], why


class TestTheReturningCustomer:
    def test_two_quotes_on_one_phone_are_one_customer(self) -> None:
        # The whole point of a twelve-month hold, and the case that was broken.
        assert customer_key_for(
            phone="012-345 6789", quote_id="q-august"
        ) == customer_key_for(phone="+60123456789", quote_id="q-march")

    def test_two_different_phones_are_two_customers(self) -> None:
        assert customer_key_for(phone="0123456789", quote_id="q-1") != customer_key_for(
            phone="0129999999", quote_id="q-1"
        )

    def test_two_walk_ins_with_no_phone_never_share_a_key(self) -> None:
        # A shared fallback would hand the second walk-in the first one's held
        # prices.
        assert customer_key_for(phone=None, quote_id="q-1") != customer_key_for(
            phone=None, quote_id="q-2"
        )

    def test_a_quote_id_cannot_be_mistaken_for_a_phone(self) -> None:
        by_phone = customer_key_for(phone="0123456789", quote_id="x")
        by_quote = customer_key_for(phone=None, quote_id="0123456789")
        assert by_phone != by_quote
        assert by_phone.value.startswith("phone:")
        assert by_quote.value.startswith("quote:")


class TestNormalisingAPhone:
    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            ("012-345 6789", "0123456789"),
            ("(012) 345.6789", "0123456789"),
            ("  0123456789  ", "0123456789"),
            ("+60123456789", "0123456789"),
            ("60123456789", "0123456789"),
            ("+60 12 345 6789", "0123456789"),
            # 060... is a real local number. Stripping a zero here would
            # produce somebody else's, and they would never know.
            ("0601234567", "0601234567"),
            ("012345678", "012345678"),
        ],
    )
    def test_it_keeps_the_number(self, raw: str, expected: str) -> None:
        assert normalise_phone(raw) == expected

    @pytest.mark.parametrize(
        "raw",
        [None, "", "   ", "call the office", "-", "0123", "01234567"],
    )
    def test_it_refuses_rather_than_guessing(self, raw: str | None) -> None:
        # A key built from a fragment matches every other fragment.
        assert normalise_phone(raw) is None

    def test_the_floor_is_nine_digits(self) -> None:
        assert MIN_PHONE_DIGITS == 9


def test_a_key_is_a_value() -> None:
    august = customer_key_for(phone="0123456789", quote_id="q-august")
    march = customer_key_for(phone="012 345 6789", quote_id="q-march")

    assert august == march
    assert len({august, march}) == 1
    assert str(august) == "phone:0123456789"
    # How the key was arrived at is part of what it means.
    assert august != CustomerKey(value="phone:0123456789", from_phone=False)

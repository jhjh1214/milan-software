"""Price override, against the same cases the Dart suite loads. SPEC.md §6.5.

If this file and ``mobile/test/pricing/price_override_test.dart`` disagree, an
override a handset applied is one the server would refuse -- and the handset is
the copy the customer was shown the price on.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.pricing.price_override import (
    MIN_REASON_LENGTH,
    OverrideRefusal,
    override_line_price,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads(
    (ROOT / "shared" / "pricing-fixtures.json").read_text(encoding="utf-8")
)
CASES = FIXTURES["price_override_cases"]


def ask(
    *,
    before_sen: int = 55200,
    after_sen: int = 50000,
    reason: str | None = "matched a competitor quote",
    admin_user_id: str | None = "u-boss",
    is_admin: bool = True,
    order_is_terminal: bool = False,
):
    return override_line_price(
        before_sen=before_sen,
        after_sen=after_sen,
        reason=reason,
        admin_user_id=admin_user_id,
        is_admin=is_admin,
        order_is_terminal=order_is_terminal,
    )


class TestTheSharedContract:
    def test_the_contract_carries_cases_at_all(self) -> None:
        assert len(CASES) >= 10

    def test_every_refusal_reason_is_exercised(self) -> None:
        covered = {
            c["expect"]["refused_because"] for c in CASES if not c["expect"]["applied"]
        }
        assert covered == {
            r.value for r in OverrideRefusal
        }, "a refusal nothing exercises is a refusal nobody has checked"

    @pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
    def test_the_fixtures_agree_with_the_rule(self, case: dict) -> None:
        result = override_line_price(
            before_sen=case["before_sen"],
            after_sen=case["after_sen"],
            reason=case["reason"],
            admin_user_id=case["admin_user_id"],
            is_admin=case["is_admin"],
            order_is_terminal=case["order_is_terminal"],
        )

        why = case["why"]
        expected = case["expect"]
        assert result.is_applied == expected["applied"], why
        if expected["applied"]:
            assert result.record is not None
            assert result.record.after_sen == expected["after_sen"], why
        else:
            assert result.refused_because is not None
            assert result.refused_because.value == expected["refused_because"], why


class TestTheAuditRow:
    def test_it_names_the_person_and_carries_both_numbers(self) -> None:
        # Without all three the weekly review cannot answer the only questions
        # it exists to answer: who, how much, and why.
        record = ask(before_sen=55200, after_sen=50000).record
        assert record is not None
        assert record.admin_user_id == "u-boss"
        assert record.before_sen == 55200
        assert record.after_sen == 50000
        assert record.reason == "matched a competitor quote"

    def test_the_reason_is_stored_trimmed(self) -> None:
        # Leading spaces from a soft keyboard would sort a row away from its
        # neighbours in the review, and the padding says nothing.
        record = ask(reason="   damp wall   ").record
        assert record is not None
        assert record.reason == "damp wall"

    def test_the_delta_is_signed_the_way_the_money_moved(self) -> None:
        down = ask(before_sen=55200, after_sen=50000).record
        up = ask(before_sen=50000, after_sen=55200).record
        assert down is not None and up is not None
        assert down.delta_sen == -5200
        assert up.delta_sen == 5200


class TestTheOrderOfTheChecks:
    def test_authority_comes_before_everything_else(self) -> None:
        # Somebody who may not do this at all should be told that, not sent off
        # to write a longer reason for a refusal that is already certain.
        assert (
            ask(is_admin=False, reason="", after_sen=-1).refused_because
            is OverrideRefusal.NOT_AN_ADMIN
        )
        assert (
            ask(admin_user_id=None, reason="", after_sen=-1).refused_because
            is OverrideRefusal.NOT_AN_ADMIN
        )

    def test_a_finished_order_is_refused_before_the_reason_is_read(self) -> None:
        assert (
            ask(order_is_terminal=True, reason="").refused_because
            is OverrideRefusal.ORDER_FINISHED
        )

    def test_an_empty_user_id_counts_as_nobody(self) -> None:
        # A blank string is what an unset field arrives as, and it names no
        # more of a person than None does.
        assert ask(admin_user_id="").refused_because is OverrideRefusal.NOT_AN_ADMIN


class TestTheBarOnTheReason:
    @pytest.mark.parametrize(
        ("reason", "refused"),
        [
            ("damp", False),
            ("  damp  ", False),
            ("dam", True),
            ("   a   ", True),
            ("", True),
            (None, True),
        ],
    )
    def test_four_characters_after_trimming(
        self, reason: str | None, refused: bool
    ) -> None:
        result = ask(reason=reason)
        assert (result.refused_because is OverrideRefusal.NO_REASON) == refused
        assert MIN_REASON_LENGTH == 4


class TestWhatItWillNotDo:
    def test_a_negative_total_is_not_a_price(self) -> None:
        # A refund is a payment of kind refund (§6.4), not a line that costs
        # less than nothing.
        assert ask(after_sen=-1).refused_because is OverrideRefusal.NEGATIVE_TOTAL
        assert ask(after_sen=-55200).refused_because is OverrideRefusal.NEGATIVE_TOTAL

    def test_zero_is_allowed_and_not_confused_with_negative(self) -> None:
        assert ask(after_sen=0).is_applied

    def test_changing_nothing_writes_nothing(self) -> None:
        # A row saying RM552 became RM552 is noise, and noise is what stops the
        # weekly review being read at all.
        assert (
            ask(before_sen=55200, after_sen=55200).refused_because
            is OverrideRefusal.NO_CHANGE
        )
        assert (
            ask(before_sen=0, after_sen=0).refused_because is OverrideRefusal.NO_CHANGE
        )

    def test_a_one_sen_move_is_a_change(self) -> None:
        # The no-op check is equality, not a tolerance. A tolerance would let
        # small corrections through unrecorded, and small is where they hide.
        assert ask(before_sen=55200, after_sen=55201).is_applied
        assert ask(before_sen=55200, after_sen=55199).is_applied

"""A staff or admin member changing one product's live price directly.

Backend-only: unlike an order-line override, a live catalog price edit has
no device-side counterpart to keep in step with, so this is a plain Python
test file rather than a shared fixture.
"""

from __future__ import annotations

from app.pricing.rate_edit import (
    MIN_REASON_LENGTH,
    RateEditRefusal,
    decide_rate_edit,
)


def ask(
    *,
    rule_id: str = "night-curtain-lo",
    list_id: str = "fair",
    before_rate_sen: int | None = 4600,
    after_rate_sen: int = 4000,
    before_mvp_rate_sen: int | None = 4000,
    after_mvp_rate_sen: int | None = 3500,
    reason: str | None = "matched a competitor quote",
    by_user_id: str = "u-boss",
):
    return decide_rate_edit(
        rule_id=rule_id,
        list_id=list_id,
        before_rate_sen=before_rate_sen,
        after_rate_sen=after_rate_sen,
        before_mvp_rate_sen=before_mvp_rate_sen,
        after_mvp_rate_sen=after_mvp_rate_sen,
        reason=reason,
        by_user_id=by_user_id,
    )


def test_a_real_change_with_a_reason_is_applied() -> None:
    decision = ask()
    assert decision.is_applied
    assert decision.record is not None
    assert decision.record.before_rate_sen == 4600
    assert decision.record.after_rate_sen == 4000
    assert decision.record.reason == "matched a competitor quote"
    assert decision.record.by_user_id == "u-boss"


def test_a_reason_is_trimmed_before_it_is_judged() -> None:
    decision = ask(reason="  matched a competitor  ")
    assert decision.is_applied
    assert decision.record is not None
    assert decision.record.reason == "matched a competitor"


def test_no_such_product_is_refused() -> None:
    # A live edit is for a product that already exists on the active card --
    # `before_rate_sen=None` is what a caller passes when the rule id does
    # not match any row.
    decision = ask(before_rate_sen=None)
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NO_SUCH_PRODUCT


def test_a_missing_reason_is_refused() -> None:
    decision = ask(reason=None)
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NO_REASON


def test_a_reason_under_the_minimum_length_is_refused() -> None:
    decision = ask(reason="a" * (MIN_REASON_LENGTH - 1))
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NO_REASON


def test_whitespace_only_is_not_a_reason() -> None:
    decision = ask(reason="    ")
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NO_REASON


def test_zero_is_refused() -> None:
    # A catalog rate of RM0 reads as "free forever", not "no price yet" --
    # the same confusion the provisional-row rule (A22) already refuses.
    decision = ask(after_rate_sen=0)
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NOT_POSITIVE


def test_negative_is_refused() -> None:
    decision = ask(after_rate_sen=-100)
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NOT_POSITIVE


def test_a_zero_mvp_rate_is_refused_even_when_the_standard_rate_is_fine() -> None:
    decision = ask(after_mvp_rate_sen=0)
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NOT_POSITIVE


def test_no_change_to_either_rate_is_refused() -> None:
    decision = ask(after_rate_sen=4600, after_mvp_rate_sen=4000)
    assert not decision.is_applied
    assert decision.refused_because is RateEditRefusal.NO_CHANGE


def test_changing_only_the_mvp_rate_is_still_a_change() -> None:
    decision = ask(after_rate_sen=4600, after_mvp_rate_sen=3800)
    assert decision.is_applied


def test_a_product_with_no_mvp_rate_can_still_be_edited() -> None:
    decision = ask(before_mvp_rate_sen=None, after_mvp_rate_sen=None)
    assert decision.is_applied
    assert decision.record is not None
    assert decision.record.after_mvp_rate_sen is None


def test_every_refusal_reason_is_reachable() -> None:
    # A refusal nothing exercises is a refusal nobody has checked.
    reachable = {
        RateEditRefusal.NO_SUCH_PRODUCT: ask(before_rate_sen=None),
        RateEditRefusal.NO_REASON: ask(reason=""),
        RateEditRefusal.NOT_POSITIVE: ask(after_rate_sen=0),
        RateEditRefusal.NO_CHANGE: ask(after_rate_sen=4600, after_mvp_rate_sen=4000),
    }
    for expected, decision in reachable.items():
        assert decision.refused_because is expected
    assert {r for r in RateEditRefusal} == set(reachable)

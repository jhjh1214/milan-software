"""PIN hashing and token minting.

Small surface, but every mistake here is the kind that is invisible until it
matters: a hash that compares equal for the wrong PIN, a token drawn from a
predictable source, a stored string that turns out to contain the PIN.
"""

from __future__ import annotations

import pytest

from app.core.security import (
    WeakPin,
    check_pin_strength,
    hash_pin,
    new_token,
    token_fingerprint,
    verify_pin,
)
from tests.helpers import assert_pin_is_not_recoverable


class TestPinHashing:
    def test_a_pin_verifies_against_its_own_hash(self) -> None:
        assert verify_pin("4821", hash_pin("4821"))

    def test_a_different_pin_does_not(self) -> None:
        assert not verify_pin("4822", hash_pin("4821"))

    def test_the_same_pin_hashes_differently_every_time(self) -> None:
        # Per-PIN salt. Without it, two people with the same PIN are visibly
        # the same row, and one rainbow table does the whole staff list.
        assert hash_pin("4821") != hash_pin("4821")

    def test_the_pin_is_not_recoverable_from_the_stored_string(self) -> None:
        assert_pin_is_not_recoverable(hash_pin("4821"), "4821")

    def test_a_user_with_no_pin_cannot_be_verified(self) -> None:
        # A part-timer created but not yet issued a PIN must not be loggable-in
        # by anyone passing an empty string.
        assert not verify_pin("4821", None)
        assert not verify_pin("", None)
        assert not verify_pin("", "")

    def test_a_corrupt_stored_hash_is_a_failure_not_a_crash(self) -> None:
        # A truncated column must deny access, not 500 the login endpoint for
        # everyone else.
        assert not verify_pin("4821", "not-a-hash")
        assert not verify_pin("4821", "scrypt$1$2$3$zz$zz")

    def test_the_scheme_is_recorded_so_the_cost_can_be_raised_later(self) -> None:
        assert hash_pin("4821").startswith("scrypt$")


class TestPinStrength:
    @pytest.mark.parametrize("pin", ["123", "1", ""])
    def test_too_short_is_refused(self, pin: str) -> None:
        with pytest.raises(WeakPin):
            check_pin_strength(pin)

    @pytest.mark.parametrize("pin", ["0000", "111111"])
    def test_one_repeated_digit_is_refused(self, pin: str) -> None:
        with pytest.raises(WeakPin):
            check_pin_strength(pin)

    @pytest.mark.parametrize("pin", ["12a4", "  12", "1234\n"])
    def test_non_digits_are_refused(self, pin: str) -> None:
        with pytest.raises(WeakPin):
            check_pin_strength(pin)

    @pytest.mark.parametrize("pin", ["4821", "482100"])
    def test_a_normal_pin_is_accepted(self, pin: str) -> None:
        check_pin_strength(pin)

    def test_hashing_refuses_a_weak_pin_rather_than_storing_it(self) -> None:
        # The check has to live at the write, not only in the admin UI.
        with pytest.raises(WeakPin):
            hash_pin("0000")


class TestTokens:
    def test_tokens_do_not_repeat(self) -> None:
        assert len({new_token() for _ in range(500)}) == 500

    def test_a_token_is_long_enough_to_be_unguessable(self) -> None:
        # 32 bytes, urlsafe-base64. It never expires, so its only defence is
        # that it cannot be guessed.
        assert len(new_token()) >= 40

    def test_the_fingerprint_is_stable_and_not_the_token(self) -> None:
        token = new_token()
        assert token_fingerprint(token) == token_fingerprint(token)
        assert token not in token_fingerprint(token)

    def test_different_tokens_fingerprint_differently(self) -> None:
        assert token_fingerprint(new_token()) != token_fingerprint(new_token())

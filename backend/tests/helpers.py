"""Assertions shared across the suite.

Small on purpose. A helper that hides what a test is checking makes the test
unreadable, so what lives here is only the thing several tests need to get
*right* rather than merely say.
"""

from __future__ import annotations

from app.core.security import hash_pin, verify_pin


def assert_pin_is_not_recoverable(stored: str | None, pin: str) -> None:
    """The stored record does not carry the PIN in any usable form.

    **Not a substring scan.** ``assert pin not in stored`` was what four tests
    used, and it is both flaky and weak.

    Flaky, because a stored record is ``scrypt$n$r$p$salt$key`` with about 190
    hex characters of salt and key in it, and every character of a numeric PIN
    is also a hex character. A four-digit PIN turns up somewhere in that string
    roughly once in 340 hashes -- five such assertions across the suite made
    about one CI run in seventy fail for no reason, on tests guarding a
    security property, which is exactly the kind of failure that gets muted.

    Weak, because a substring miss says nothing. What matters is that the PIN
    cannot be *recovered*, and that is three things:

    * the record is the documented format, and no field of it **is** the PIN;
    * it verifies the right PIN and refuses a wrong one;
    * the same PIN hashes differently every time, so one rainbow table does not
      do the whole staff list.
    """
    assert stored is not None, "nothing was stored"

    fields = stored.split("$")
    assert fields[0] == "scrypt", f"unexpected scheme: {fields[0]}"
    assert len(fields) == 6, f"expected scheme, n, r, p, salt, key: {stored}"
    assert pin not in fields, "the PIN is stored as a field of the record"

    assert verify_pin(pin, stored), "the real PIN does not verify"
    assert not verify_pin(pin + "9", stored), "a wrong PIN verifies"

    assert stored != hash_pin(pin), "the hash is not salted"

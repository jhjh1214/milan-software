"""PIN hashing and session tokens.

Two different problems, hashed two different ways on purpose.

A **PIN** is four to six digits. That is a million guesses at most, so the only
thing standing between a stolen database and every staff PIN is how slow the
hash is. scrypt, from the standard library, with parameters chosen so a single
verification costs real time and memory.

A **token** is 256 bits from ``secrets``. There is nothing to brute-force, so it
is stored as a plain SHA-256 digest -- which also makes it a usable lookup key.
Slow-hashing it would buy nothing and would put a KDF on the hot path of every
authenticated request.

Nothing here imports FastAPI or SQLAlchemy: it is testable on its own.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets

#: ~64MB and a few hundred milliseconds per verification on a small VPS. Chosen
#: to be expensive against a stolen database, and still unnoticeable to someone
#: typing a PIN once at the start of a shift.
_SCRYPT_N = 2**16
_SCRYPT_R = 8
_SCRYPT_P = 1
_SALT_BYTES = 16
_KEY_BYTES = 32

#: Recorded in the stored string so the cost can be raised later without
#: invalidating every existing PIN.
_SCHEME = "scrypt"

MIN_PIN_LENGTH = 4
MAX_PIN_LENGTH = 12


class WeakPin(ValueError):
    """The PIN is too short, or is not digits."""


def _derive(pin: str, salt: bytes, n: int, r: int, p: int) -> bytes:
    return hashlib.scrypt(
        pin.encode("utf-8"),
        salt=salt,
        n=n,
        r=r,
        p=p,
        dklen=_KEY_BYTES,
        # scrypt's memory ceiling is derived from the parameters; the default
        # is too small for n=2**16 and raises ValueError without this.
        maxmem=256 * 1024 * 1024,
    )


def hash_pin(pin: str) -> str:
    """``scrypt$n$r$p$salt$key``, all hex. Self-describing, so raising the cost
    later does not invalidate PINs hashed at the old one."""
    check_pin_strength(pin)
    salt = secrets.token_bytes(_SALT_BYTES)
    key = _derive(pin, salt, _SCRYPT_N, _SCRYPT_R, _SCRYPT_P)
    return "$".join(
        [
            _SCHEME,
            str(_SCRYPT_N),
            str(_SCRYPT_R),
            str(_SCRYPT_P),
            salt.hex(),
            key.hex(),
        ]
    )


def verify_pin(pin: str, stored: str | None) -> bool:
    """Constant-time check. False for a user with no PIN set, never a crash."""
    if not stored:
        return False
    try:
        scheme, n, r, p, salt_hex, key_hex = stored.split("$")
        if scheme != _SCHEME:
            return False
        expected = bytes.fromhex(key_hex)
        actual = _derive(pin, bytes.fromhex(salt_hex), int(n), int(r), int(p))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(expected, actual)


def check_pin_strength(pin: str) -> None:
    """Rejects a PIN nobody should be issued.

    Deliberately not a password policy. These are typed on a phone at a fair by
    someone holding a tape measure; length and "not 0000" is the whole of it.
    The real control on an override is the audit log naming a person, not the
    gate (SPEC.md §6.5).
    """
    if not pin.isdigit():
        raise WeakPin("a PIN is digits only")
    if not MIN_PIN_LENGTH <= len(pin) <= MAX_PIN_LENGTH:
        raise WeakPin(
            f"a PIN is {MIN_PIN_LENGTH} to {MAX_PIN_LENGTH} digits, got {len(pin)}"
        )
    if len(set(pin)) == 1:
        raise WeakPin("a PIN of one repeated digit is not a PIN")


def new_token() -> str:
    """A session token. 256 bits of urandom -- unguessable, so it never expires
    on its own (SPEC.md §12: no token expiry may lock a user out mid-fair)."""
    return secrets.token_urlsafe(32)


def token_fingerprint(token: str) -> str:
    """What is stored. The token itself never touches the database, so a leaked
    dump does not hand over live sessions."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()

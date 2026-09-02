"""Money, held as integer sen.

Mirrors `mobile/lib/core/money.dart`. CLAUDE.md: RM46.00 is 4600; `float` for
currency is forbidden, and `Decimal` only at boundaries.

Quantities are `fractions.Fraction`, which is Python's exact rational and the
counterpart of the hand-rolled `Rational` on the Dart side. Keeping the two
shaped alike is what lets `shared/pricing-fixtures.json` hold both engines to
the same number.
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction


@dataclass(frozen=True, order=True)
class Money:
    """An amount in Malaysian sen. 100 sen to the ringgit.

    May be negative: refunds exist from Phase 4.
    """

    sen: int

    @classmethod
    def rm(cls, ringgit: int, sen: int = 0) -> Money:
        return cls(ringgit * 100 + sen)

    @classmethod
    def round_from(cls, exact_sen: Fraction) -> Money:
        """Rounds an exact amount to the nearest sen, half away from zero.

        **Call this once per line total and never on an intermediate.** Rounding
        a quantity, then a unit rate, then a total compounds three errors no
        customer can reproduce on a calculator.

        Half away from zero rather than banker's: banker's would under-collect
        on a long invoice and would not match the printed price list.
        """
        return cls(_round_half_up(exact_sen))

    def __add__(self, other: Money) -> Money:
        return Money(self.sen + other.sen)

    def __sub__(self, other: Money) -> Money:
        return Money(self.sen - other.sen)

    def __mul__(self, factor: int) -> Money:
        return Money(self.sen * factor)

    def __neg__(self) -> Money:
        return Money(-self.sen)

    @property
    def is_zero(self) -> bool:
        return self.sen == 0

    def max(self, other: Money) -> Money:
        return self if self.sen >= other.sen else other

    def min(self, other: Money) -> Money:
        return self if self.sen <= other.sen else other

    def format(self, *, with_symbol: bool = True) -> str:
        """Formats as ``RM 1,234.50``.

        Always two decimals with the RM prefix, per §8.3 -- never a bare number.
        """
        negative = self.sen < 0
        value = abs(self.sen)
        body = f"{value // 100:,}.{value % 100:02d}"
        signed = f"-{body}" if negative else body
        return f"RM {signed}" if with_symbol else signed

    def to_plain_string(self) -> str:
        """``1500.00`` -- two decimals, no grouping, no symbol.

        For machine-readable output. ``format`` groups thousands with a comma,
        which is right on a quote and wrong in a CSV cell, where the comma
        splits the field and the row silently loses a column.
        """
        negative = self.sen < 0
        value = abs(self.sen)
        body = f"{value // 100}.{value % 100:02d}"
        return f"-{body}" if negative else body

    def __str__(self) -> str:
        return self.format()


ZERO = Money(0)


def _round_half_up(value: Fraction) -> int:
    if value.denominator == 1:
        return value.numerator
    if value < 0:
        return -_round_half_up(-value)
    return (2 * value.numerator + value.denominator) // (2 * value.denominator)

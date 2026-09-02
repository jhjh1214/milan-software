"""Lengths, held as integer tenths of a millimetre.

Mirrors `mobile/lib/core/length.dart`. The two must agree exactly, because
`shared/pricing-fixtures.json` holds both to the same numbers and §9.4 has the
server re-price every line the app sends.

## Why tenths and not whole millimetres

A foot is 304.8mm. No whole-millimetre value represents it, so storing
millimetres loses the difference between "the customer said twelve feet" and
"the tape read 3658mm" -- and that loss is a wrong price:

    12ft -> 3657.6mm -> stored 3658mm -> 12.0013 ft -> ceils to 13 ft
    13 ft x RM46 = RM598, where the golden test demands RM552.

In tenths every unit is an exact integer, so no conversion rounds at all:

    mm 10 | cm 100 | m 10000 | inch 254 | foot 3048
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from fractions import Fraction

#: Tenths of a millimetre in one foot. 304.8mm, exactly.
TENTHS_PER_FOOT = 3048

#: Tenths of a square millimetre in one square foot: 3048 * 3048.
TENTHS_SQ_PER_SQFT = 9_290_304


class LengthUnit(Enum):
    """The units a dimension can be entered in.

    Chinese units share their values with the imperial ones: 尺 is the foot and
    寸 the inch as this trade uses them, not the historical 市尺.
    """

    MM = ("mm", 10)
    CM = ("cm", 100)
    M = ("m", 10_000)
    INCH = ("in", 254)
    FOOT = ("ft", TENTHS_PER_FOOT)

    def __init__(self, symbol: str, tenths_per_unit: int) -> None:
        self.symbol = symbol
        #: Always an integer -- that is the whole reason lengths are in tenths.
        self.tenths_per_unit = tenths_per_unit


@dataclass(frozen=True, order=True)
class Length:
    """A dimension. Immutable, integer tenths of a millimetre, never negative.

    Persisted columns carrying this value are named ``*_tmm``, never ``*_mm``.
    """

    tmm: int

    def __post_init__(self) -> None:
        if self.tmm < 0:
            raise ValueError(f"a length cannot be negative: {self.tmm}")

    @classmethod
    def of(cls, value: Fraction | int, unit: LengthUnit) -> Length:
        """Converts an exact quantity of ``unit`` into a length.

        Exact for every unit and every input the trade types. The half-up
        fallback only engages for input finer than a tenth of a millimetre.
        """
        exact = Fraction(value) * unit.tenths_per_unit
        return cls(_round_half_up(exact))

    @classmethod
    def from_mm(cls, mm: int) -> Length:
        return cls(mm * 10)

    @property
    def mm(self) -> int:
        """Whole millimetres, rounded half-up.

        **Display and diagnostics only.** Never feed this back into a length or
        a price: that is the round-trip tenths exist to prevent.
        """
        return (self.tmm + 5) // 10

    @property
    def feet_exact(self) -> Fraction:
        """The width in feet, unrounded. What final pricing bills (A11)."""
        return Fraction(self.tmm, TENTHS_PER_FOOT)

    @property
    def feet_ceil(self) -> int:
        """Feet rounded up to the next whole foot -- the quotation rule (A10).

        Exact in both directions: exactly 12ft bills 12ft, and one tenth of a
        millimetre more bills 13ft.
        """
        return _ceil(self.feet_exact)

    @property
    def is_zero(self) -> bool:
        return self.tmm == 0

    def __str__(self) -> str:
        return f"{self.tmm}tmm ({self.mm}mm)"


def area_sqft(width: Length, height: Length) -> Fraction:
    """The exact area of a rectangle in square feet, unrounded.

    Exact for any whole-foot or whole-inch rectangle: 3ft x 4ft is 12, not
    11.9928.
    """
    return Fraction(width.tmm * height.tmm, TENTHS_SQ_PER_SQFT)


def _ceil(value: Fraction) -> int:
    """Smallest integer >= value. Exact: a value that is 96 ceils to 96."""
    if value.denominator == 1:
        return value.numerator
    return -((-value.numerator) // value.denominator)


def _round_half_up(value: Fraction) -> int:
    """Rounds half away from zero. Mirrors Dart's ``Rational.roundHalfUpToInt``."""
    if value.denominator == 1:
        return value.numerator
    if value < 0:
        return -_round_half_up(-value)
    return (2 * value.numerator + value.denominator) // (2 * value.denominator)

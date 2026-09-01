/// Lengths, held as integer **tenths of a millimetre**.
///
/// ## Why tenths and not whole millimetres
///
/// A foot is 304.8mm. No whole-millimetre value can represent it, so storing
/// millimetres loses the difference between "the customer said twelve feet" and
/// "the tape read 3658mm". That loss is not cosmetic — it produces a wrong
/// price:
///
///     12ft -> 3657.6mm -> stored 3658mm -> 12.0013 ft -> ceils to 13 ft
///     13 ft x RM46 = RM598, where the golden test demands RM552.
///
/// That is precisely the `mm -> ft -> mm` round-trip CLAUDE.md forbids, and
/// whole millimetres make it unavoidable rather than merely tempting.
///
/// In tenths of a millimetre every unit this app accepts is an exact integer:
///
///     mm 10 | cm 100 | m 10000 | inch 254 | foot 3048
///
/// so no conversion rounds at all, `3ft x 4ft` is exactly 12.0000 sqft rather
/// than 11.9928, and the foot ceiling is exact in both directions.
library;

import 'rational.dart';

/// The units a dimension can be entered in.
///
/// Chinese units share their values with the imperial ones: 尺 is the foot and
/// 寸 the inch as this trade uses them, not the historical 市尺.
enum LengthUnit {
  mm('mm', 10),
  cm('cm', 100),
  m('m', 10000),
  inch('in', 254),
  foot('ft', 3048);

  const LengthUnit(this.symbol, this.tenthsPerUnit);

  /// The short symbol shown on the unit chip beside a dimension field.
  final String symbol;

  /// Exact tenths of a millimetre in one of this unit. Always an integer —
  /// that is the entire reason this class stores tenths.
  final int tenthsPerUnit;
}

/// A dimension. Immutable, integer tenths of a millimetre, never negative.
class Length implements Comparable<Length> {
  /// The dimension in tenths of a millimetre. This is the storage unit.
  ///
  /// Persisted columns carrying this value are named `*_tmm`, not `*_mm`.
  final int tmm;

  const Length._(this.tmm);

  /// Creates a length from tenths of a millimetre. Throws if negative.
  factory Length.tenths(int tmm) {
    if (tmm < 0) {
      throw ArgumentError.value(tmm, 'tmm', 'A length cannot be negative');
    }
    return Length._(tmm);
  }

  /// Creates a length from whole millimetres.
  factory Length.mm(int mm) => Length.tenths(mm * 10);

  /// Converts an exact quantity of [unit] into a length.
  ///
  /// For every unit and every input the trade actually types, this is exact —
  /// nothing is rounded. The half-up fallback only engages for input finer than
  /// a tenth of a millimetre, such as `1.23456m`.
  factory Length.of(Rational value, LengthUnit unit) => Length.tenths(
    (value * Rational.fromInt(unit.tenthsPerUnit)).roundHalfUpToInt(),
  );

  static const Length zero = Length._(0);

  /// Tenths of a millimetre in one foot. 304.8mm, exactly.
  static const int tenthsPerFoot = 3048;

  /// Tenths of a square millimetre in one square foot: 3048 * 3048.
  static const int tenthsSqPerSqft = 9290304;

  /// The dimension in whole millimetres, rounded half-up.
  ///
  /// **Display and diagnostics only.** Never feed this back into a length or a
  /// price — that is the round-trip this class exists to prevent.
  int get mm => (tmm + 5) ~/ 10;

  /// The exact width in feet, unrounded.
  ///
  /// This is what final pricing bills, after a site measurement (A11).
  Rational get feetExact => Rational(tmm, tenthsPerFoot);

  /// The width in feet rounded up to the next whole foot.
  ///
  /// The quotation billing convention (A10). Exact in both directions: an
  /// entry of exactly 12ft bills 12ft, and one tenth of a millimetre more
  /// bills 13ft.
  int get feetCeil => feetExact.ceilToInt();

  /// The whole-foot part, for display as `12尺 4寸`.
  int get displayFeet => feetExact.floorToInt();

  /// The leftover inches after [displayFeet], rounded to the nearest inch.
  int get displayInches {
    final remainder = feetExact - Rational.fromInt(displayFeet);
    return (remainder * const Rational.fromInt(12)).roundHalfUpToInt();
  }

  bool get isZero => tmm == 0;

  @override
  int compareTo(Length other) => tmm.compareTo(other.tmm);

  bool operator <(Length o) => tmm < o.tmm;
  bool operator <=(Length o) => tmm <= o.tmm;
  bool operator >(Length o) => tmm > o.tmm;
  bool operator >=(Length o) => tmm >= o.tmm;

  @override
  bool operator ==(Object other) => other is Length && other.tmm == tmm;

  @override
  int get hashCode => tmm.hashCode;

  @override
  String toString() => '${tmm}tmm (${mm}mm)';
}

/// The exact area of a rectangle in square feet, unrounded.
///
/// Exact for any whole-foot or whole-inch rectangle: `3ft x 4ft` is 12, not
/// 11.9928.
Rational areaSqft(Length width, Length height) =>
    Rational(width.tmm * height.tmm, Length.tenthsSqPerSqft);

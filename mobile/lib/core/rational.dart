/// Exact rational arithmetic. No floating point anywhere in this file.
///
/// Why this exists: a foot is 304.8mm, so ft -> mm -> sqft can never be exact
/// in binary. A 12ft x 8ft blind that computes as 96.0000000001 sqft would ceil
/// to 97 and overcharge the customer by a whole square foot. See CLAUDE.md,
/// "Quantity arithmetic is exact rational, never float".
///
/// Deliberately mirrors Python's `fractions.Fraction`, which the FastAPI engine
/// uses in Phase 3. Keeping the two implementations shaped alike is what lets
/// `shared/pricing-fixtures.json` hold both sides to the same number.
library;

/// A rational number held as an exact integer fraction, always normalised so
/// that the denominator is positive and `gcd(n, d) == 1`.
///
/// Values in this system stay far inside the 64-bit range: the largest
/// realistic intermediate is a 20ft x 20ft area in tenths of a mm, around
/// 3.7e9, and multiplying by a rate in sen keeps it under 1e14.
class Rational implements Comparable<Rational> {
  /// Numerator. Carries the sign.
  final int n;

  /// Denominator. Always strictly positive.
  final int d;

  const Rational._(this.n, this.d);

  /// Creates `n / d`, normalised. Throws if [d] is zero.
  factory Rational(int n, [int d = 1]) {
    if (d == 0) {
      throw ArgumentError.value(d, 'd', 'Rational denominator cannot be zero');
    }
    if (n == 0) return zero;
    var num = n;
    var den = d;
    if (den < 0) {
      num = -num;
      den = -den;
    }
    final g = _gcd(num.abs(), den);
    return Rational._(num ~/ g, den ~/ g);
  }

  /// Creates a whole number.
  const Rational.fromInt(int value) : n = value, d = 1;

  static const Rational zero = Rational._(0, 1);
  static const Rational one = Rational._(1, 1);

  /// Parses a non-negative decimal string such as `"7"`, `"7.5"` or `"2.4"`
  /// into an exact fraction. Returns null if [s] is not such a number.
  ///
  /// `"2.4"` becomes 24/10, not the nearest double to 2.4. That distinction is
  /// the whole point: `2.4m` must land on exactly 2400mm.
  static Rational? tryParseDecimal(String s) {
    if (s.isEmpty) return null;
    // `int.tryParse` tolerates surrounding whitespace and a leading sign, so
    // " 7", "+7" and "-7" would all slip through. Callers currently hand this
    // clean regex captures, but a value type should not depend on that.
    if (!_digitsAndPoint.hasMatch(s)) return null;
    final dot = s.indexOf('.');
    if (dot == -1) {
      final v = int.tryParse(s);
      return v == null ? null : Rational.fromInt(v);
    }
    if (s.indexOf('.', dot + 1) != -1) return null; // more than one point
    final whole = s.substring(0, dot);
    final frac = s.substring(dot + 1);
    if (frac.isEmpty) return null; // "7." is not a number we accept
    // Guard against absurd precision producing an overflowing denominator.
    if (frac.length > 6) return null;
    final wholeValue = whole.isEmpty ? 0 : int.tryParse(whole);
    final fracValue = int.tryParse(frac);
    if (wholeValue == null || fracValue == null) return null;
    final scale = _pow10(frac.length);
    return Rational(wholeValue * scale + fracValue, scale);
  }

  bool get isZero => n == 0;
  bool get isInteger => d == 1;
  bool get isNegative => n < 0;

  Rational operator +(Rational o) => Rational(n * o.d + o.n * d, d * o.d);
  Rational operator -(Rational o) => Rational(n * o.d - o.n * d, d * o.d);
  Rational operator *(Rational o) => Rational(n * o.n, d * o.d);

  Rational operator /(Rational o) {
    if (o.isZero) throw ArgumentError('Division by zero');
    return Rational(n * o.d, d * o.n);
  }

  Rational operator -() => Rational._(-n, d);

  /// The smallest integer greater than or equal to this value.
  ///
  /// This is the quotation rounding (SPEC.md §4.3 step 5b, A10). It is exact:
  /// a value that is mathematically 96 ceils to 96, never 97.
  int ceilToInt() {
    if (d == 1) return n;
    // Dart's ~/ truncates toward zero, so floor and ceil differ by sign.
    return n > 0 ? (n + d - 1) ~/ d : -((-n) ~/ d);
  }

  /// The largest integer less than or equal to this value.
  int floorToInt() {
    if (d == 1) return n;
    return n > 0 ? n ~/ d : -(((-n) + d - 1) ~/ d);
  }

  /// Rounds half away from zero. `2.5 -> 3`, `-2.5 -> -3`, `0.25 -> 0`.
  ///
  /// This is the money rounding (CLAUDE.md: "round half-up to the nearest sen,
  /// once, at the line total"). Half-away-from-zero, not banker's rounding —
  /// bankers' would under-collect on a long invoice and would not match the
  /// printed price list.
  int roundHalfUpToInt() {
    if (d == 1) return n;
    if (n < 0) return -Rational._(-n, d).roundHalfUpToInt();
    return (2 * n + d) ~/ (2 * d);
  }

  /// Lossy. For display and diagnostics only — never for pricing.
  double toDouble() => n / d;

  Rational max(Rational o) => compareTo(o) >= 0 ? this : o;
  Rational min(Rational o) => compareTo(o) <= 0 ? this : o;

  @override
  int compareTo(Rational o) => (n * o.d).compareTo(o.n * d);

  bool operator <(Rational o) => compareTo(o) < 0;
  bool operator <=(Rational o) => compareTo(o) <= 0;
  bool operator >(Rational o) => compareTo(o) > 0;
  bool operator >=(Rational o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Rational && other.n == n && other.d == d;

  @override
  int get hashCode => Object.hash(n, d);

  @override
  String toString() => d == 1 ? '$n' : '$n/$d';

  /// Digits, with at most one decimal point. No sign, no whitespace.
  static final RegExp _digitsAndPoint = RegExp(r'^\d*\.?\d*$');

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a == 0 ? 1 : a;
  }

  static int _pow10(int e) {
    var r = 1;
    for (var i = 0; i < e; i++) {
      r *= 10;
    }
    return r;
  }
}

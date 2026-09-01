import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/rational.dart';

/// Rational underpins every price in the system, so it is tested exhaustively
/// rather than incidentally through the engine.
void main() {
  group('construction and normalisation', () {
    test('fractions reduce to lowest terms', () {
      expect(Rational(2, 4), Rational(1, 2));
      expect(Rational(37592, 3048), Rational(37, 3));
      expect(Rational(100, 10), Rational.fromInt(10));
    });

    test('the sign always lives on the numerator', () {
      expect(Rational(1, -2), Rational(-1, 2));
      expect(Rational(1, -2).d, 2);
      expect(Rational(-1, -2), Rational(1, 2));
    });

    test('zero normalises regardless of denominator', () {
      expect(Rational(0, 7), Rational.zero);
      expect(Rational.zero.isZero, isTrue);
    });

    test('a zero denominator is rejected, not silently absorbed', () {
      expect(() => Rational(1, 0), throwsArgumentError);
    });

    test('whole numbers report themselves as integers', () {
      expect(Rational.fromInt(12).isInteger, isTrue);
      expect(Rational(1, 2).isInteger, isFalse);
      expect(Rational.one.isInteger, isTrue);
    });

    test('negativity is reported from the numerator', () {
      expect(Rational(-1, 2).isNegative, isTrue);
      expect(Rational(1, 2).isNegative, isFalse);
      expect(Rational.zero.isNegative, isFalse);
    });
  });

  group('parsing decimals exactly', () {
    test('a decimal string becomes an exact fraction, not a double', () {
      // 2.4 is not representable in binary. 24/10 is exact, and that is what
      // makes `2.4m` land on exactly 2400mm.
      expect(Rational.tryParseDecimal('2.4'), Rational(24, 10));
      expect(Rational.tryParseDecimal('7.5'), Rational(15, 2));
      expect(Rational.tryParseDecimal('12'), Rational.fromInt(12));
      expect(Rational.tryParseDecimal('0.05'), Rational(1, 20));
    });

    test('a leading point is accepted', () {
      expect(Rational.tryParseDecimal('.5'), Rational(1, 2));
    });

    test('malformed input returns null rather than a guess', () {
      for (final bad in ['', 'abc', '7.', '1.2.3', '7,5', ' 7', '7 ']) {
        expect(
          Rational.tryParseDecimal(bad),
          isNull,
          reason: '"$bad" must not parse',
        );
      }
    });

    test('precision beyond a millionth is refused rather than overflowing', () {
      expect(Rational.tryParseDecimal('1.1234567'), isNull);
      expect(Rational.tryParseDecimal('1.123456'), isNotNull);
    });
  });

  group('arithmetic', () {
    test('addition and subtraction', () {
      expect(Rational(1, 2) + Rational(1, 3), Rational(5, 6));
      expect(Rational(1, 2) - Rational(1, 3), Rational(1, 6));
      expect(Rational(1, 2) - Rational(1, 2), Rational.zero);
    });

    test('multiplication and division', () {
      expect(Rational(2, 3) * Rational(3, 4), Rational(1, 2));
      expect(Rational(1, 2) / Rational(1, 4), Rational.fromInt(2));
      expect(Rational.fromInt(37) / Rational.fromInt(3), Rational(37, 3));
    });

    test('dividing by zero is rejected', () {
      expect(() => Rational.one / Rational.zero, throwsArgumentError);
    });

    test('negation', () {
      expect(-Rational(1, 2), Rational(-1, 2));
      expect(-Rational(-1, 2), Rational(1, 2));
      expect(-Rational.zero, Rational.zero);
    });
  });

  group('ceiling — the quotation rounding', () {
    test('a whole number ceils to itself', () {
      expect(Rational.fromInt(96).ceilToInt(), 96);
      expect(Rational(192, 2).ceilToInt(), 96);
    });

    test('any fraction above a whole number ceils upward', () {
      expect(Rational(97, 96).ceilToInt(), 2);
      expect(Rational(1, 1000000).ceilToInt(), 1);
      expect(Rational(12, 5).ceilToInt(), 3);
    });

    test('negatives ceil toward zero', () {
      expect(Rational(-12, 5).ceilToInt(), -2);
      expect(Rational(-5, 1).ceilToInt(), -5);
    });
  });

  group('floor', () {
    test('positives', () {
      expect(Rational(12, 5).floorToInt(), 2);
      expect(Rational.fromInt(12).floorToInt(), 12);
    });

    test('negatives floor away from zero', () {
      expect(Rational(-12, 5).floorToInt(), -3);
      expect(Rational.fromInt(-12).floorToInt(), -12);
    });
  });

  group('half-up rounding — the money rounding', () {
    test('exactly one half always goes away from zero', () {
      expect(Rational(1, 2).roundHalfUpToInt(), 1);
      expect(Rational(3, 2).roundHalfUpToInt(), 2);
      expect(Rational(5, 2).roundHalfUpToInt(), 3);
      expect(Rational(-1, 2).roundHalfUpToInt(), -1);
      expect(Rational(-5, 2).roundHalfUpToInt(), -3);
    });

    test('below and above the half', () {
      expect(Rational(1, 4).roundHalfUpToInt(), 0);
      expect(Rational(3, 4).roundHalfUpToInt(), 1);
      expect(Rational(-3, 4).roundHalfUpToInt(), -1);
    });

    test('whole numbers are untouched', () {
      expect(Rational.fromInt(7).roundHalfUpToInt(), 7);
      expect(Rational.fromInt(-7).roundHalfUpToInt(), -7);
    });
  });

  group('comparison', () {
    test('compareTo orders correctly across denominators', () {
      expect(Rational(1, 3).compareTo(Rational(1, 2)), lessThan(0));
      expect(Rational(1, 2).compareTo(Rational(1, 3)), greaterThan(0));
      expect(Rational(2, 4).compareTo(Rational(1, 2)), 0);
    });

    test('the comparison operators agree with compareTo', () {
      final a = Rational(1, 3);
      final b = Rational(1, 2);
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(a > b, isFalse);
      expect(a >= b, isFalse);
      expect(b > a, isTrue);
      expect(b >= a, isTrue);
      expect(a <= Rational(2, 6), isTrue);
      expect(a >= Rational(2, 6), isTrue);
    });

    test('max and min', () {
      expect(Rational(1, 3).max(Rational(1, 2)), Rational(1, 2));
      expect(Rational(1, 2).max(Rational(1, 3)), Rational(1, 2));
      expect(Rational(1, 3).min(Rational(1, 2)), Rational(1, 3));
      expect(Rational(1, 2).min(Rational(1, 3)), Rational(1, 3));
      // The minimum-quantity path relies on max returning the receiver when
      // the two are equal.
      expect(Rational.fromInt(18).max(Rational.fromInt(18)), Rational.fromInt(18));
      expect(Rational.fromInt(18).min(Rational.fromInt(18)), Rational.fromInt(18));
    });
  });

  group('value semantics', () {
    test('equality is by reduced value, not by construction', () {
      expect(Rational(2, 4) == Rational(1, 2), isTrue);
      expect(Rational(1, 2) == Rational(1, 3), isFalse);
      expect(Rational(1, 2) == Object(), isFalse);
    });

    test('equal values share a hash code', () {
      expect(Rational(2, 4).hashCode, Rational(1, 2).hashCode);
      final set = {Rational(1, 2), Rational(2, 4), Rational(1, 3)};
      expect(set.length, 2);
    });

    test('toString is readable in both forms', () {
      expect(Rational.fromInt(12).toString(), '12');
      expect(Rational(37, 3).toString(), '37/3');
      expect(Rational(2, 4).toString(), '1/2');
    });
  });

  group('toDouble is for display only', () {
    test('it converts, with the loss that implies', () {
      expect(Rational(1, 2).toDouble(), 0.5);
      expect(Rational(37, 3).toDouble(), closeTo(12.3333, 0.0001));
    });
  });
}

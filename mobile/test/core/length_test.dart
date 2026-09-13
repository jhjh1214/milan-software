import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/length_parser.dart';
import 'package:milan_quote/core/rational.dart';

void main() {
  group('storage unit — tenths of a millimetre', () {
    test('every accepted unit is an exact integer number of tenths', () {
      // This is the property that makes the whole design work. If any unit
      // needed a fraction of a tenth, conversions would round and the foot
      // ceiling would drift again.
      expect(LengthUnit.mm.tenthsPerUnit, 10);
      expect(LengthUnit.cm.tenthsPerUnit, 100);
      expect(LengthUnit.m.tenthsPerUnit, 10000);
      expect(LengthUnit.inch.tenthsPerUnit, 254);
      expect(LengthUnit.foot.tenthsPerUnit, 3048);
    });

    test('mm is a display accessor and rounds half-up', () {
      expect(Length.tenths(36576).mm, 3658); // 3657.6mm
      expect(Length.tenths(30480).mm, 3048);
    });
  });

  group('foot ceiling — the quotation rounding', () {
    test('3048mm is exactly 10ft and stays 10', () {
      expect(Length.mm(3048).feetCeil, 10);
    });

    test('3049mm is over 10ft and becomes 11', () {
      expect(Length.mm(3049).feetCeil, 11);
    });

    test('12ft 4in bills as 13ft', () {
      expect(Length.of(Rational.fromInt(12), LengthUnit.foot).tmm, 36576);
      expect(Length.tenths(12 * 3048 + 4 * 254).feetCeil, 13);
    });

    test('zero stays zero', () {
      expect(Length.zero.feetCeil, 0);
    });

    test('every whole foot ceils to itself, never one more', () {
      for (var ft = 1; ft <= 60; ft++) {
        expect(
          Length.of(Rational.fromInt(ft), LengthUnit.foot).feetCeil,
          ft,
          reason: 'exactly ${ft}ft must not ceil to ${ft + 1}',
        );
      }
    });

    test('one tenth of a millimetre over a whole foot ceils upward', () {
      for (var ft = 1; ft <= 20; ft++) {
        expect(Length.tenths(ft * 3048 + 1).feetCeil, ft + 1);
      }
    });
  });

  group('regression — the mm round-trip that overcharged RM46', () {
    // Storing whole millimetres made 12ft become 3658mm, which converts back to
    // 12.0013ft and ceils to 13ft. The customer was quoted RM598 where golden
    // row 1 demands RM552. Tenths removed the round-trip entirely.
    test('entering 12ft bills 12ft, not 13', () {
      final entered = parseLength('12ft', LengthUnit.mm)!;
      expect(entered.length.tmm, 36576);
      expect(entered.length.feetCeil, 12, reason: 'RM552, not RM598');
    });

    test("12' and 12ft and 12尺 all bill 12ft", () {
      for (final input in ["12'", '12ft', '12尺', "12'0"]) {
        expect(
          parseLength(input, LengthUnit.mm)!.length.feetCeil,
          12,
          reason: '"$input" must bill 12ft',
        );
      }
    });

    test('a tape reading of 3658mm still bills 13ft', () {
      // The distinction whole millimetres destroyed: 3658mm really is over
      // 12ft, so ceiling to 13 is correct here and wrong for "12ft".
      expect(parseLength('3658mm', LengthUnit.mm)!.length.feetCeil, 13);
    });
  });

  group('exact feet — the final-pricing quantity', () {
    test('an exact foot value is a whole number', () {
      expect(Length.mm(3048).feetExact, Rational.fromInt(10));
      expect(
        Length.of(Rational.fromInt(12), LengthUnit.foot).feetExact,
        Rational.fromInt(12),
      );
    });

    test('12ft 4in measured on site bills exactly, not rounded up', () {
      // A11. 12ft 4in = 37592 tenths; 37592/3048 = 12.3333 ft.
      final l = Length.tenths(12 * 3048 + 4 * 254);
      expect(l.feetExact.toDouble(), closeTo(12.3333, 0.0001));
      expect(l.feetCeil, 13, reason: 'the quotation still rounds up');
    });
  });

  group('unit conversion is exact, never rounded', () {
    test('feet and inches', () {
      expect(Length.of(Rational.fromInt(10), LengthUnit.foot).tmm, 30480);
      expect(Length.of(Rational(75, 10), LengthUnit.foot).tmm, 22860);
      expect(Length.of(Rational.fromInt(84), LengthUnit.inch).tmm, 21336);
    });

    test('metric', () {
      expect(Length.of(Rational(24, 10), LengthUnit.m).tmm, 24000);
      expect(Length.of(Rational.fromInt(240), LengthUnit.cm).tmm, 24000);
      expect(Length.of(Rational.fromInt(2400), LengthUnit.mm).tmm, 24000);
    });

    test('a negative length is rejected outright', () {
      expect(() => Length.tenths(-1), throwsArgumentError);
    });
  });

  group('display — entered value alongside billed value', () {
    test('12ft 4in reads back as 12 feet 4 inches', () {
      final l = Length.tenths(12 * 3048 + 4 * 254);
      expect(l.displayFeet, 12);
      expect(l.displayInches, 4);
    });

    test('an exact foot has no leftover inches', () {
      expect(Length.mm(3048).displayFeet, 10);
      expect(Length.mm(3048).displayInches, 0);
    });
  });

  group('comparison and value semantics', () {
    test('compareTo orders by tenths', () {
      expect(Length.mm(100).compareTo(Length.mm(200)), lessThan(0));
      expect(Length.mm(200).compareTo(Length.mm(100)), greaterThan(0));
      expect(Length.mm(100).compareTo(Length.mm(100)), 0);
    });

    test('the operators agree with compareTo', () {
      final a = Length.mm(100);
      final b = Length.mm(200);
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(a > b, isFalse);
      expect(a >= b, isFalse);
      expect(b > a, isTrue);
      expect(b >= a, isTrue);
      expect(a <= Length.mm(100), isTrue);
      expect(a >= Length.mm(100), isTrue);
    });

    test('a list of lengths sorts correctly', () {
      final lengths = [Length.mm(300), Length.zero, Length.mm(100)]..sort();
      expect(lengths.map((l) => l.mm), [0, 100, 300]);
    });

    test('equality is by stored tenths', () {
      expect(Length.mm(3048) == Length.tenths(30480), isTrue);
      expect(Length.mm(3048) == Length.tenths(30481), isFalse);
      expect(Length.mm(3048) == Object(), isFalse);
    });

    test('equal lengths share a hash code', () {
      expect(Length.mm(3048).hashCode, Length.tenths(30480).hashCode);
      final set = <Length>{}
        ..add(Length.mm(3048))
        ..add(Length.tenths(30480));
      expect(set.length, 1);
    });

    test('toString shows both units, so a log is never ambiguous', () {
      expect(Length.tenths(36576).toString(), '36576tmm (3658mm)');
    });

    test('isZero', () {
      expect(Length.zero.isZero, isTrue);
      expect(Length.tenths(1).isZero, isFalse);
    });
  });

  group('area in square feet is exact', () {
    test('a whole-foot rectangle is a whole number of square feet', () {
      // Whole millimetres made this 11.9928, which is visibly wrong to anyone
      // who multiplies 3 by 4.
      final area = areaSqft(
        Length.of(Rational.fromInt(3), LengthUnit.foot),
        Length.of(Rational.fromInt(4), LengthUnit.foot),
      );
      expect(area, Rational.fromInt(12));
      expect(area.isInteger, isTrue);
    });

    test('5ft x 4ft at RM9/sqft is RM180.00, not RM179.97', () {
      final area = areaSqft(
        Length.of(Rational.fromInt(5), LengthUnit.foot),
        Length.of(Rational.fromInt(4), LengthUnit.foot),
      );
      expect(area, Rational.fromInt(20));
    });

    test('12ft x 8ft is exactly 96 sqft and never ceils to 97', () {
      final area = areaSqft(
        Length.of(Rational.fromInt(12), LengthUnit.foot),
        Length.of(Rational.fromInt(8), LengthUnit.foot),
      );
      expect(area, Rational.fromInt(96));
      expect(area.ceilToInt(), 96);
    });

    test('every whole-foot rectangle up to 20x20 is exact', () {
      for (var w = 1; w <= 20; w++) {
        for (var h = 1; h <= 20; h++) {
          final area = areaSqft(
            Length.of(Rational.fromInt(w), LengthUnit.foot),
            Length.of(Rational.fromInt(h), LengthUnit.foot),
          );
          expect(area, Rational.fromInt(w * h), reason: '${w}ft x ${h}ft');
        }
      }
    });
  });

  group('a saved room\'s area, converted exactly', () {
    test('9.290304 square metres is exactly 100 sqft', () {
      // 1 sqft is 9,290,304 tenths-mm² exactly, and 1mm² is 100 tenths-mm² --
      // so a room of that many mm² is exactly 100 sqft, not 99.9999997.
      expect(areaSqftFromMm2(9290304), Rational.fromInt(100));
    });

    test('a non-whole area stays exact, never a float', () {
      // Picked so the division does not land on a whole number: this is the
      // same 700/3 the shared pricing fixtures hold both engines to.
      expect(areaSqftFromMm2(21677376), Rational(700, 3));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/length_parser.dart';

/// SPEC.md §5.3 is a table, so this is a table test. Every row of the spec
/// appears here, including every row whose expected result is null.
void main() {
  group('SPEC.md §5.3 parser table', () {
    // (input, defaultUnit, expected mm or null)
    const cases = <(String, LengthUnit, int?)>[
      // Bare number takes the chip's unit.
      ('84', LengthUnit.inch, 2134),
      ('84', LengthUnit.mm, 84),
      ('84', LengthUnit.cm, 840),

      // Inches, however they are written.
      ('84in', LengthUnit.mm, 2134),
      ('84"', LengthUnit.mm, 2134),
      ('84 inch', LengthUnit.mm, 2134),
      ('84寸', LengthUnit.mm, 2134),

      // Feet, however they are written.
      ('7ft', LengthUnit.mm, 2134),
      ("7'", LengthUnit.mm, 2134),
      ('7尺', LengthUnit.mm, 2134),

      // Feet and inches together. SPEC marks this "must work".
      ("7'6", LengthUnit.mm, 2286),
      ("7'6\"", LengthUnit.mm, 2286),
      ('7ft6', LengthUnit.mm, 2286),
      ('7ft 6in', LengthUnit.mm, 2286),
      ('7尺6寸', LengthUnit.mm, 2286),

      // Metric.
      ('2400mm', LengthUnit.inch, 2400),
      ('2.4m', LengthUnit.inch, 2400),
      ('2.4米', LengthUnit.inch, 2400),
      ('240cm', LengthUnit.inch, 2400),

      // Fractional feet.
      ('7.5ft', LengthUnit.mm, 2286),

      // Zero inches must not be dropped.
      ("12'0", LengthUnit.mm, 3658),

      // Everything below is an inline error, never a guess.
      ('', LengthUnit.mm, null),
      ('   ', LengthUnit.mm, null),
      ('abc', LengthUnit.mm, null),
      ("7''6", LengthUnit.mm, null),
      ('-5', LengthUnit.mm, null),
      ('0', LengthUnit.mm, null),
      ('0mm', LengthUnit.mm, null),
      ('7.5.2', LengthUnit.mm, null),
      ('7.', LengthUnit.mm, null),
      ('12 x 8', LengthUnit.mm, null),
      ('ft', LengthUnit.mm, null),
    ];

    for (final (input, unit, expected) in cases) {
      test(
        '"$input" with chip on ${unit.symbol} -> ${expected ?? "error"}',
        () {
          final result = parseLength(input, unit);
          if (expected == null) {
            expect(result, isNull, reason: 'must not fall back to a guess');
          } else {
            expect(result, isNotNull, reason: '"$input" should parse');
            expect(result!.length.mm, expected);
          }
        },
      );
    }
  });

  group('acceptance criteria', () {
    test("7'6 and 2286mm produce identical results", () {
      final a = parseLength("7'6", LengthUnit.mm)!;
      final b = parseLength('2286mm', LengthUnit.mm)!;
      expect(a.length, b.length);
      expect(a.length.mm, 2286);
    });

    test('a suffix overrides the chip', () {
      final result = parseLength('2400mm', LengthUnit.inch)!;
      expect(result.length.mm, 2400);
      expect(result.unit, LengthUnit.mm);
      expect(result.unitWasExplicit, isTrue);
    });

    test('a bare number defers to the chip and says so', () {
      final result = parseLength('84', LengthUnit.inch)!;
      expect(result.unitWasExplicit, isFalse);
      expect(result.unit, LengthUnit.inch);
    });

    test('the raw entry is preserved for display', () {
      // §5.5: never show more precision than was entered.
      expect(parseLength("  7'6  ", LengthUnit.mm)!.raw, "7'6");
    });
  });

  group('deliberate rejections', () {
    test('fractional feet combined with inches is an error, not a guess', () {
      // 7.5ft6in has two plausible readings and no obvious intent.
      expect(parseLength('7.5ft6in', LengthUnit.mm), isNull);
    });

    test('absurd decimal precision is rejected rather than overflowing', () {
      expect(parseLength('1.1234567m', LengthUnit.mm), isNull);
    });
  });

  group('case insensitivity', () {
    test('unit suffixes accept either case', () {
      expect(parseLength('7FT', LengthUnit.mm)!.length.mm, 2134);
      expect(parseLength('2400MM', LengthUnit.inch)!.length.mm, 2400);
      expect(parseLength('84IN', LengthUnit.mm)!.length.mm, 2134);
    });
  });
}

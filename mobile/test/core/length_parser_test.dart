import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/length_parser.dart';

/// SPEC.md §5.3 is a table, so this is a table test. Every row of the spec
/// appears here, including every row whose expected result is null.
///
/// **Expectations are in tenths of a millimetre**, exactly as §5.3 states them.
///
/// They used to be in whole millimetres, read back through `Length.mm`, and
/// that could not see the bug the `_tmm` invariant exists to prevent: a parser
/// that rounds to whole millimetres on the way in turns `7ft` into 21340 tmm
/// instead of 21336, and `.mm` reports 2134 either way. Rounding a parse is how
/// `12ft` becomes 13ft on a quote and overcharges RM46 on one window.
///
/// Every accepted unit is an exact whole number of tenths, so **nothing here
/// should round at all** — which is the point.
void main() {
  group('SPEC.md §5.3 parser table', () {
    // (input, defaultUnit, expected TENTHS of a millimetre, or null)
    const cases = <(String, LengthUnit, int?)>[
      // Bare number takes the chip's unit.
      ('84', LengthUnit.inch, 21336),
      ('84', LengthUnit.mm, 840),
      ('84', LengthUnit.cm, 8400),

      // Inches, however they are written. 84 x 254 = 21336, exactly.
      ('84in', LengthUnit.mm, 21336),
      ('84"', LengthUnit.mm, 21336),
      ('84 inch', LengthUnit.mm, 21336),
      ('84寸', LengthUnit.mm, 21336),

      // Feet, however they are written. 7 x 3048 = 21336 — the same length as
      // 84in, to the tenth, which is only true because neither rounded.
      ('7ft', LengthUnit.mm, 21336),
      ("7'", LengthUnit.mm, 21336),
      ('7尺', LengthUnit.mm, 21336),

      // Feet and inches together. SPEC marks this "must work".
      ("7'6", LengthUnit.mm, 22860),
      ("7'6\"", LengthUnit.mm, 22860),
      ('7ft6', LengthUnit.mm, 22860),
      ('7ft 6in', LengthUnit.mm, 22860),
      ('7尺6寸', LengthUnit.mm, 22860),

      // Metric.
      ('8000mm', LengthUnit.inch, 80000),
      ('2400mm', LengthUnit.inch, 24000),
      ('2.4m', LengthUnit.inch, 24000),
      ('2.4米', LengthUnit.inch, 24000),
      ('240cm', LengthUnit.inch, 24000),

      // Fractional feet. 7.5 x 3048 = 22860, exactly the same as 7'6".
      ('7.5ft', LengthUnit.mm, 22860),

      // The wide sliding door in §5.4's worked example, both ways of writing it.
      ('96in', LengthUnit.mm, 24384),
      ('8ft', LengthUnit.mm, 24384),
      ("8'", LengthUnit.mm, 24384),

      // Zero inches must not be dropped.
      ("12'0", LengthUnit.mm, 36576),

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
            expect(
              result!.length.tmm,
              expected,
              reason:
                  'exact tenths. Rounding a parse to whole millimetres is the '
                  'round-trip that turns 12ft into 13ft on a quote',
            );
          }
        },
      );
    }

    test('every accepted unit lands on a whole number of tenths', () {
      // The table above only proves it for the values in it. This proves the
      // property: a foot is 304.8mm, so millimetres cannot represent one -- but
      // tenths can represent every unit the parser accepts, exactly.
      const perUnit = <LengthUnit, int>{
        LengthUnit.mm: 10,
        LengthUnit.cm: 100,
        LengthUnit.m: 10000,
        LengthUnit.inch: 254,
        LengthUnit.foot: 3048,
      };

      for (final entry in perUnit.entries) {
        expect(
          entry.key.tenthsPerUnit,
          entry.value,
          reason: '${entry.key.symbol} must be a whole number of tenths',
        );

        // And one of that unit really parses to exactly that many tenths.
        final parsed = parseLength('1${entry.key.symbol}', LengthUnit.mm);
        if (parsed != null) {
          expect(parsed.length.tmm, entry.value, reason: entry.key.symbol);
        }
      }
    });
  });

  group('acceptance criteria', () {
    test("7'6 and 2286mm produce identical results", () {
      final a = parseLength("7'6", LengthUnit.mm)!;
      final b = parseLength('2286mm', LengthUnit.mm)!;
      expect(a.length, b.length);
      expect(a.length.tmm, 22860);
    });

    test('the same length written five ways is the same tenths', () {
      // §5.1: parse then normalise. Once normalised, how it was typed is gone
      // -- and if two spellings of one length disagreed by a tenth, they would
      // disagree by a whole foot after ceiling on a quote.
      final spellings = [
        parseLength('7ft', LengthUnit.mm)!,
        parseLength("7'", LengthUnit.mm)!,
        parseLength('84in', LengthUnit.mm)!,
        parseLength('84"', LengthUnit.mm)!,
        parseLength('7尺', LengthUnit.mm)!,
      ];

      expect(
        spellings.map((s) => s.length.tmm).toSet(),
        {21336},
        reason: 'one length, five spellings, one exact value',
      );
    });

    test('a suffix overrides the chip', () {
      final result = parseLength('2400mm', LengthUnit.inch)!;
      expect(result.length.tmm, 24000);
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

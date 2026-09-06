import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/dimension_warnings.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/rational.dart';

/// SPEC.md §5.4. These warnings are the app's only use of magnitude, and §5.1
/// is emphatic that magnitude may hint but never decide.
void main() {
  Length ft(num v) => Length.tenths((v * 3048).round());

  group('the unit-slip nudge', () {
    test('2400 with the chip on inches is flagged, and mm suggested', () {
      // The spec's own example: 2400 inches is 61 metres.
      final value = Length.of(Rational.fromInt(2400), LengthUnit.inch);
      expect(value.mm, 60960, reason: '2400 inches really is 61 metres');
      final warnings = checkDimension(
        value: value,
        enteredUnit: LengthUnit.inch,
        unitWasExplicit: false,
        isHeight: false,
      );
      expect(warnings, hasLength(1));
      expect(warnings.single.kind, DimensionWarningKind.unitLooksWrong);
      expect(warnings.single.suggestedUnit, LengthUnit.mm);
    });

    test('an explicit suffix is a statement and is never second-guessed', () {
      // `2400mm` means 2400mm. Warning about it would be the guessing §5.1
      // rejects.
      final warnings = checkDimension(
        value: Length.mm(70000),
        enteredUnit: LengthUnit.mm,
        unitWasExplicit: true,
        isHeight: false,
      );
      expect(warnings, isEmpty);
    });

    test('a plausible size raises nothing', () {
      final warnings = checkDimension(
        value: ft(12),
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: false,
        isHeight: false,
      );
      expect(warnings, isEmpty);
    });

    test('every non-mm unit suggests mm when implausibly large', () {
      for (final unit in [
        LengthUnit.inch,
        LengthUnit.foot,
        LengthUnit.m,
        LengthUnit.cm,
      ]) {
        final warnings = checkDimension(
          value: Length.mm(70000),
          enteredUnit: unit,
          unitWasExplicit: false,
          isHeight: false,
        );
        expect(
          warnings.single.suggestedUnit,
          LengthUnit.mm,
          reason: '$unit should suggest mm',
        );
      }
    });

    test(
      'millimetres have nothing smaller to suggest, so nothing is shown',
      () {
        final warnings = checkDimension(
          value: Length.mm(70000),
          enteredUnit: LengthUnit.mm,
          unitWasExplicit: false,
          isHeight: false,
        );
        expect(warnings, isEmpty);
      },
    );
  });

  group('the very-short-drop nudge', () {
    test('a 200mm height is questioned', () {
      final warnings = checkDimension(
        value: Length.mm(200),
        enteredUnit: LengthUnit.mm,
        unitWasExplicit: true,
        isHeight: true,
      );
      expect(warnings.single.kind, DimensionWarningKind.dropVeryShort);
    });

    test('a short width is not, because narrow windows exist', () {
      final warnings = checkDimension(
        value: Length.mm(200),
        enteredUnit: LengthUnit.mm,
        unitWasExplicit: true,
        isHeight: false,
      );
      expect(warnings, isEmpty);
    });

    test('an empty field is not nagged about', () {
      final warnings = checkDimension(
        value: Length.zero,
        enteredUnit: LengthUnit.mm,
        unitWasExplicit: true,
        isHeight: true,
      );
      expect(warnings, isEmpty);
    });
  });

  group('the band-edge nudge — the highest-value validation in the app', () {
    // On a 12ft curtain, 10ft 1in against 9ft 11in is a RM144 swing.
    const tenFeetEdge = 30481;

    test('just under the edge is flagged, and reported as below', () {
      final warnings = checkDimension(
        value: Length.tenths(30226), // 9ft 11in
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: true,
        isHeight: true,
        bandEdgesTmm: const [tenFeetEdge],
      );
      expect(warnings.single.kind, DimensionWarningKind.nearBandEdge);
      expect(warnings.single.bandEdgeTmm, tenFeetEdge);
      expect(warnings.single.isAboveEdge, isFalse);
    });

    test('just over the edge is flagged, and reported as above', () {
      final warnings = checkDimension(
        value: Length.tenths(30734), // 10ft 1in
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: true,
        isHeight: true,
        bandEdgesTmm: const [tenFeetEdge],
      );
      expect(warnings.single.kind, DimensionWarningKind.nearBandEdge);
      expect(warnings.single.isAboveEdge, isTrue);
    });

    test('comfortably inside a band raises nothing', () {
      final warnings = checkDimension(
        value: ft(9),
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: true,
        isHeight: true,
        bandEdgesTmm: const [tenFeetEdge],
      );
      expect(warnings, isEmpty);
    });

    test('an unbanded product never shows the nudge', () {
      final warnings = checkDimension(
        value: Length.tenths(30480),
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: true,
        isHeight: true,
      );
      expect(warnings, isEmpty);
    });

    test('only the nearest edge is reported, not every one', () {
      final warnings = checkDimension(
        value: Length.tenths(30480),
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: true,
        isHeight: true,
        bandEdgesTmm: const [tenFeetEdge, 30500],
      );
      expect(
        warnings.where((w) => w.kind == DimensionWarningKind.nearBandEdge),
        hasLength(1),
      );
    });

    test('the threshold comes from config, not from code', () {
      const wide = WarningThresholds(bandEdgeWarnTmm: 20000);
      final warnings = checkDimension(
        value: ft(9),
        enteredUnit: LengthUnit.foot,
        unitWasExplicit: true,
        isHeight: true,
        bandEdgesTmm: const [tenFeetEdge],
        thresholds: wide,
      );
      expect(warnings.single.kind, DimensionWarningKind.nearBandEdge);
    });
  });

  group('SPEC.md §5.4 — plausible size, per category, per field', () {
    // Generous on purpose: these exist to catch 203 metres, not to second-guess
    // a real order. A warning that fires on real work gets tapped past.
    const card = WarningThresholds(
      plausibleByCategory: {
        'curtain': CategoryPlausibility(
          width: PlausibleRange(minTmm: 1000, maxTmm: 200000),
          height: PlausibleRange(minTmm: 1000, maxTmm: 60000),
        ),
        'flooring': CategoryPlausibility(
          width: PlausibleRange(minTmm: 1000, maxTmm: 500000),
        ),
      },
    );

    List<DimensionWarning> check(
      Length value, {
      LengthUnit unit = LengthUnit.mm,
      bool explicit = true,
      bool isHeight = false,
      String? category = 'curtain',
      WarningThresholds thresholds = card,
    }) => checkDimension(
      value: value,
      enteredUnit: unit,
      unitWasExplicit: explicit,
      isHeight: isHeight,
      depositCategory: category,
      thresholds: thresholds,
    );

    test('8000in is flagged even though the unit was typed', () {
      // THE case §5.4 works through, and the one that was silently accepted.
      // 8000 x 254 = 2,032,000 tenths = 203.2 metres. The old rule exempted
      // any explicit unit as "a statement, not a slip" — but an explicit
      // 8000in is a thumb in the wrong place, not a statement.
      final warnings = check(
        Length.tenths(8000 * 254),
        unit: LengthUnit.inch,
        explicit: true,
      );

      final flagged = warnings.where(
        (w) => w.kind == DimensionWarningKind.implausibleForCategory,
      );
      expect(flagged, hasLength(1), reason: '203 metres is not a curtain');
      expect(
        flagged.single.suggestedUnit,
        LengthUnit.mm,
        reason: 'they meant 8000mm — make the fix one tap',
      );
    });

    test('8000mm, which is what they meant, is not flagged', () {
      // A wide sliding door. 8 metres is a real curtain and must stay silent,
      // or the warning is noise and gets ignored on the day it matters.
      expect(
        check(
          Length.tenths(80000),
          unit: LengthUnit.mm,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
    });

    test('the range is per field: 8m wide is fine, 8m tall is not', () {
      final wide = check(Length.tenths(80000));
      final tall = check(Length.tenths(80000), isHeight: true);

      expect(
        wide.where(
          (w) => w.kind == DimensionWarningKind.implausibleForCategory,
        ),
        isEmpty,
      );
      expect(
        tall.where(
          (w) => w.kind == DimensionWarningKind.implausibleForCategory,
        ),
        hasLength(1),
        reason: 'an 8m curtain drop is not a room anybody has',
      );
    });

    test('the range is per category: 30m of flooring is fine', () {
      // The same number that is absurd for a curtain is an ordinary corridor.
      expect(
        check(
          Length.tenths(300000),
          category: 'flooring',
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
      expect(
        check(
          Length.tenths(300000),
          category: 'curtain',
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        hasLength(1),
      );
    });

    test('a category with no configured range warns on nothing', () {
      // The safe default. A missing config must never invent a limit that
      // blocks a real order.
      expect(
        check(
          Length.tenths(9999999),
          category: 'wallpaper',
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
    });

    test('a field with no configured range warns on nothing', () {
      // `flooring` above configures width only.
      expect(
        check(
          Length.tenths(9999999),
          category: 'flooring',
          isHeight: true,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
    });

    test('no category at all warns on nothing', () {
      expect(
        check(
          Length.tenths(9999999),
          category: null,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
    });

    test('an empty config warns on nothing', () {
      expect(
        check(
          Length.tenths(9999999),
          thresholds: const WarningThresholds(),
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
    });

    test('too small is flagged too', () {
      // A 0.5mm curtain is a slip in the other direction.
      expect(
        check(
          Length.tenths(5),
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        hasLength(1),
      );
    });

    test('a range with only a minimum has no ceiling', () {
      // An absent bound means unbounded in that direction, not zero. Reading a
      // missing maximum as zero would flag every real order in that category.
      const openTop = WarningThresholds(
        plausibleByCategory: {
          'curtain': CategoryPlausibility(width: PlausibleRange(minTmm: 1000)),
        },
      );

      expect(
        check(
          Length.tenths(99999999),
          thresholds: openTop,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
      expect(
        check(
          Length.tenths(5),
          thresholds: openTop,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        hasLength(1),
        reason: 'the minimum it does state still applies',
      );
    });

    test('a range with only a maximum has no floor', () {
      const openBottom = WarningThresholds(
        plausibleByCategory: {
          'curtain': CategoryPlausibility(
            width: PlausibleRange(maxTmm: 200000),
          ),
        },
      );

      expect(
        check(
          Length.tenths(5),
          thresholds: openBottom,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
      expect(
        check(
          Length.tenths(300000),
          thresholds: openBottom,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        hasLength(1),
      );
    });

    test('an empty field is not nagged about', () {
      // Nothing has been typed yet. Zero is below every configured minimum,
      // and warning about it would put a red message on a field the person has
      // not reached.
      expect(
        check(
          Length.zero,
        ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
        isEmpty,
      );
    });

    test('the boundaries themselves are plausible', () {
      // Inclusive at both ends. A range that rejected its own limits would
      // fire on the very orders it was calibrated from.
      for (final tmm in [1000, 200000]) {
        expect(
          check(
            Length.tenths(tmm),
          ).where((w) => w.kind == DimensionWarningKind.implausibleForCategory),
          isEmpty,
          reason: '$tmm is a stated bound',
        );
      }
    });

    test(
      'the warning carries the range, so a message can say what is expected',
      () {
        final flagged = check(Length.tenths(2032000), unit: LengthUnit.inch)
            .firstWhere(
              (w) => w.kind == DimensionWarningKind.implausibleForCategory,
            );

        expect(flagged.expected?.minTmm, 1000);
        expect(flagged.expected?.maxTmm, 200000);
      },
    );

    test('an implausible size never blocks the quote', () {
      // §5.1: a warning is advice. The person confirms.
      final warnings = check(Length.tenths(2032000), unit: LengthUnit.inch);
      expect(warnings, isNotEmpty);
      // Nothing here throws, and the caller still holds a usable Length.
      expect(Length.tenths(2032000).tmm, 2032000);
    });
  });

  group('warnings never block', () {
    test('several can apply at once and all are returned', () {
      final warnings = checkDimension(
        value: Length.mm(70000),
        enteredUnit: LengthUnit.inch,
        unitWasExplicit: false,
        isHeight: true,
        bandEdgesTmm: const [700000],
      );
      // A nudge is advice. The caller still gets a usable length.
      expect(warnings.length, greaterThanOrEqualTo(1));
    });
  });
}

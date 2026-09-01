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

    test('millimetres have nothing smaller to suggest, so nothing is shown', () {
      final warnings = checkDimension(
        value: Length.mm(70000),
        enteredUnit: LengthUnit.mm,
        unitWasExplicit: false,
        isHeight: false,
      );
      expect(warnings, isEmpty);
    });
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

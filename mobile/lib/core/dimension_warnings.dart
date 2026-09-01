/// Soft warnings on entered dimensions. SPEC.md §5.4.
///
/// **Non-blocking, always one tap to fix.** A warning never prevents a quote —
/// §5.1 is explicit that magnitude is used only as a hint and never as a
/// decision. Getting this wrong turns a helpful nudge into the guessing the
/// whole unit design rejects.
///
/// PURE. Thresholds are passed in, not compiled in — §5.4 requires them in
/// config.
library;

import 'length.dart';

/// What kind of nudge to show.
enum DimensionWarningKind {
  /// The value is implausibly large for the chosen unit — probably a unit slip.
  unitLooksWrong,

  /// A curtain drop under the plausible minimum.
  dropVeryShort,

  /// Close enough to a band boundary that a small measuring error flips the
  /// price. §5.4 calls this "the highest-value validation in the app".
  nearBandEdge,
}

/// A non-blocking nudge about one entered dimension.
class DimensionWarning {
  final DimensionWarningKind kind;

  /// For [DimensionWarningKind.unitLooksWrong], the unit being suggested.
  final LengthUnit? suggestedUnit;

  /// For [DimensionWarningKind.nearBandEdge], the boundary in tenths of a mm.
  final int? bandEdgeTmm;

  /// True when the entered value sits above the boundary rather than below,
  /// so the message can say "just over" rather than "just under".
  final bool? isAboveEdge;

  const DimensionWarning({
    required this.kind,
    this.suggestedUnit,
    this.bandEdgeTmm,
    this.isAboveEdge,
  });
}

/// Thresholds for the soft warnings. Config, not code.
class WarningThresholds {
  /// Above this, a dimension is almost certainly a unit slip. Default 20ft.
  final int implausiblyLargeTmm;

  /// Below this, a curtain drop is almost certainly wrong. Default 300mm.
  final int implausiblyShortDropTmm;

  /// How close to a band edge triggers the price nudge. Default 76mm ≈ 3in.
  final int bandEdgeWarnTmm;

  const WarningThresholds({
    this.implausiblyLargeTmm = 60960, // 20ft
    this.implausiblyShortDropTmm = 3000, // 300mm
    this.bandEdgeWarnTmm = 760, // 76mm
  });
}

/// Checks one dimension and returns any warnings that apply.
///
/// [bandEdgesTmm] are the boundaries of the bands the chosen product uses.
/// Pass an empty list when the product is unbanded.
List<DimensionWarning> checkDimension({
  required Length value,
  required LengthUnit enteredUnit,
  required bool unitWasExplicit,
  required bool isHeight,
  List<int> bandEdgesTmm = const [],
  WarningThresholds thresholds = const WarningThresholds(),
}) {
  final warnings = <DimensionWarning>[];

  // A value only plausible if the unit were smaller. Suggest the smaller one.
  // Only when the unit came from the chip — an explicit `2400mm` is a
  // statement, not a slip.
  if (!unitWasExplicit && value.tmm > thresholds.implausiblyLargeTmm) {
    final suggestion = switch (enteredUnit) {
      LengthUnit.inch || LengthUnit.foot => LengthUnit.mm,
      LengthUnit.m => LengthUnit.mm,
      LengthUnit.cm => LengthUnit.mm,
      LengthUnit.mm => null,
    };
    if (suggestion != null) {
      warnings.add(
        DimensionWarning(
          kind: DimensionWarningKind.unitLooksWrong,
          suggestedUnit: suggestion,
        ),
      );
    }
  }

  if (isHeight &&
      !value.isZero &&
      value.tmm < thresholds.implausiblyShortDropTmm) {
    warnings.add(
      const DimensionWarning(kind: DimensionWarningKind.dropVeryShort),
    );
  }

  // The band-edge nudge. On a 12ft curtain, 10ft 1in against 9ft 11in is a
  // RM144 swing, so this is worth interrupting for.
  for (final edge in bandEdgesTmm) {
    final distance = (value.tmm - edge).abs();
    if (distance <= thresholds.bandEdgeWarnTmm) {
      warnings.add(
        DimensionWarning(
          kind: DimensionWarningKind.nearBandEdge,
          bandEdgeTmm: edge,
          isAboveEdge: value.tmm >= edge,
        ),
      );
      break;
    }
  }

  return warnings;
}

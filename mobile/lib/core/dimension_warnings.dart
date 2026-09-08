/// Soft warnings on entered dimensions. SPEC.md §5.5.
///
/// **Non-blocking, always one tap to fix.** A warning never prevents a quote —
/// §5.1 is explicit that magnitude is used only as a hint and never as a
/// decision. Getting this wrong turns a helpful nudge into the guessing the
/// whole unit design rejects.
///
/// PURE. Thresholds are passed in, not compiled in — §5.5 requires them in
/// config.
library;

import 'length.dart';
import 'rational.dart';

/// The unit a raw typed number most plausibly means, when the unit actually
/// selected produced something too large to be real.
///
/// **Never used to decide what a value means** — §5.3 forbids guessing
/// interpretation from magnitude. This only picks which one-tap fix a
/// warning offers, and offering the wrong one is worse than offering none:
/// a bare `21` on the foot chip is a normal window, and "did you mean 21
/// millimetres?" is not a fix anyone typing a real window ever meant. A bare
/// `2000`, on the other hand, is squarely the scale a floor plan is
/// dimensioned in — nobody hand-measures 2000 of anything else this trade
/// sells.
///
/// SPEC.md §5.3 names 50–300 the ambiguous band on purpose and refuses to
/// guess inside it (`84` is a plausible inch drop and a plausible cm width).
/// Below it a bare number reads as feet or inches, which is how this trade
/// actually measures; only clear of it does millimetres become the obvious
/// read, so this stays silent rather than force a coin flip.
LengthUnit? _plausibleSmallerUnit(Length value, LengthUnit enteredUnit) {
  if (enteredUnit == LengthUnit.mm) return null; // Already the finest unit.
  final raw = Rational(value.tmm, enteredUnit.tenthsPerUnit);
  return raw > const Rational.fromInt(300) ? LengthUnit.mm : null;
}

/// What kind of nudge to show.
enum DimensionWarningKind {
  /// The value is implausibly large for the chosen unit — probably a unit slip.
  unitLooksWrong,

  /// A curtain or blind **drop** under the plausible minimum.
  ///
  /// Only ever raised where the second dimension really is a drop. A 300mm
  /// floor length is a strip at a doorway, not a suspiciously short curtain,
  /// and asking about it teaches people to tap past warnings.
  dropVeryShort,

  /// Close enough to a band boundary that a small measuring error flips the
  /// price. §5.5 calls this "the highest-value validation in the app".
  nearBandEdge,

  /// Physically impossible for this kind of product. §5.5's worked example:
  /// `8000in` is 203 metres, and no curtain, window or floor in this business
  /// is 203 metres.
  ///
  /// Unlike [unitLooksWrong] this fires **even when the unit was typed
  /// explicitly**. An explicit `2400mm` is a statement; an explicit `8000in`
  /// is a thumb in the wrong place, and treating it as a statement is how a
  /// 203-metre curtain reaches a quote.
  implausibleForCategory,
}

/// A non-blocking nudge about one entered dimension.
class DimensionWarning {
  final DimensionWarningKind kind;

  /// For [DimensionWarningKind.unitLooksWrong], the unit being suggested.
  final LengthUnit? suggestedUnit;

  /// For [DimensionWarningKind.nearBandEdge], the boundary in tenths of a mm.
  final int? bandEdgeTmm;

  /// For [DimensionWarningKind.implausibleForCategory], the range that was
  /// expected — so the message can say what a curtain actually is, rather than
  /// only that this is not one.
  final PlausibleRange? expected;

  /// True when the entered value sits above the boundary rather than below,
  /// so the message can say "just over" rather than "just under".
  final bool? isAboveEdge;

  const DimensionWarning({
    required this.kind,
    this.suggestedUnit,
    this.bandEdgeTmm,
    this.isAboveEdge,
    this.expected,
  });
}

/// How big a thing of this kind can physically be. SPEC.md §5.5.
///
/// Either end may be absent, which means unbounded in that direction. A range
/// that is absent entirely warns on nothing — a missing config must never
/// invent a limit that blocks a real order.
class PlausibleRange {
  const PlausibleRange({this.minTmm, this.maxTmm});

  final int? minTmm;
  final int? maxTmm;

  bool covers(int tmm) =>
      (minTmm == null || tmm >= minTmm!) && (maxTmm == null || tmm <= maxTmm!);
}

/// The plausible ranges for one deposit category, per field.
///
/// The two are separate because they are different questions, and what the
/// second one *is* depends on the product: a six-metre curtain **drop** is a
/// double-height living room, a six-metre floor **length** is an ordinary
/// bedroom, and a six-metre width is a wall of windows.
class CategoryPlausibility {
  const CategoryPlausibility({this.width, this.second});

  final PlausibleRange? width;

  /// The drop, the floor length or the wall height, depending on the family.
  /// See `SecondDimension` in `pricing/models.dart`.
  final PlausibleRange? second;

  PlausibleRange? forField({required bool isSecondDimension}) =>
      isSecondDimension ? second : width;
}

/// Thresholds for the soft warnings. Config, not code.
class WarningThresholds {
  /// Above this, a dimension is almost certainly a unit slip. Default 20ft.
  final int implausiblyLargeTmm;

  /// Below this, a curtain drop is almost certainly wrong. Default 300mm.
  final int implausiblyShortDropTmm;

  /// How close to a band edge triggers the price nudge. Default 76mm ≈ 3in.
  final int bandEdgeWarnTmm;

  /// What each deposit category can physically measure, per field. §5.5.
  ///
  /// Empty by default and empty for any category the card does not configure,
  /// which warns on nothing. That is the safe direction: a missing config must
  /// not invent a limit that blocks a real order.
  final Map<String, CategoryPlausibility> plausibleByCategory;

  const WarningThresholds({
    this.implausiblyLargeTmm = 60960, // 20ft
    this.implausiblyShortDropTmm = 3000, // 300mm
    this.bandEdgeWarnTmm = 760, // 76mm
    this.plausibleByCategory = const {},
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
  required bool isSecondDimension,

  /// Whether this product's second dimension is a **drop** — a curtain or a
  /// blind — rather than a floor length or a wall height.
  ///
  /// A plain flag rather than the `SecondDimension` enum because `core/` must
  /// not depend on `pricing/`; the caller, which knows the family, decides.
  bool secondIsDrop = true,
  String? depositCategory,
  List<int> bandEdgesTmm = const [],
  WarningThresholds thresholds = const WarningThresholds(),
}) {
  final warnings = <DimensionWarning>[];

  // Physically impossible for this kind of product. §5.5's worked example:
  // `8000in` is 203 metres.
  //
  // **Checked regardless of whether the unit was typed.** The explicit-unit
  // exemption below exists so an explicit `2400mm` is not second-guessed — but
  // an explicit `8000in` is not a statement either, it is a thumb in the wrong
  // place, and exempting it is how a 203-metre curtain reaches a quote.
  //
  // No configured range for this category means no warning.
  final range = depositCategory == null
      ? null
      : thresholds.plausibleByCategory[depositCategory]?.forField(
          isSecondDimension: isSecondDimension,
        );
  if (range != null && !value.isZero && !range.covers(value.tmm)) {
    warnings.add(
      DimensionWarning(
        kind: DimensionWarningKind.implausibleForCategory,
        expected: range,
        suggestedUnit: _plausibleSmallerUnit(value, enteredUnit),
      ),
    );
  }

  // A value only plausible if the unit were smaller. Suggest the smaller one,
  // and only when there is one the raw number actually supports — see
  // `_plausibleSmallerUnit`. Only when the unit came from the chip — an
  // explicit `2400mm` is a statement, not a slip.
  if (!unitWasExplicit && value.tmm > thresholds.implausiblyLargeTmm) {
    final suggestion = _plausibleSmallerUnit(value, enteredUnit);
    if (suggestion != null) {
      warnings.add(
        DimensionWarning(
          kind: DimensionWarningKind.unitLooksWrong,
          suggestedUnit: suggestion,
        ),
      );
    }
  }

  // Only where the second dimension really is a drop. A 300mm floor length is
  // a strip at a doorway; questioning it is how people learn to tap past
  // warnings, including the one that matters.
  if (isSecondDimension &&
      secondIsDrop &&
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

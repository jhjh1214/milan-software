/// The pricing engine.
///
/// PURE. No Flutter imports, no I/O, no clock reads. Runnable in a test with no
/// UI, no database and no network — see CLAUDE.md.
///
/// Implements SPEC.md §4.3. The Python engine in `backend/app/pricing` mirrors
/// this file step for step, and `shared/pricing-fixtures.json` holds both to
/// the same numbers.
library;

import '../core/length.dart';
import '../core/money.dart';
import '../core/rational.dart';
import 'models.dart';

/// Thrown when no rule covers the requested product and dimensions.
///
/// **Never fall back to the cheapest matching rule.** A missing band is a data
/// error and must surface as one; guessing produces a confident wrong price.
class NoApplicableRate implements Exception {
  final String variant;
  final String? materialKey;
  final Length? bandValue;
  final String detail;

  NoApplicableRate({
    required this.variant,
    required this.materialKey,
    required this.bandValue,
    required this.detail,
  });

  @override
  String toString() =>
      'NoApplicableRate: $variant'
      '${materialKey == null ? '' : ' ($materialKey)'} — $detail';
}

/// One line, as the engine priced it.
///
/// Carries everything `order_lines` records, so the quote, the PDF and the
/// server re-price all read the same numbers rather than recomputing them.
class PricedLine {
  /// The rule that produced this price.
  final PricingRule rule;

  /// The stage this was priced at. Determines whether quantity was rounded.
  final PricingStage stage;

  /// The exact quantity before any rounding or minimum.
  final Rational rawQty;

  /// The quantity actually charged for, after minimum and stage rounding.
  final Rational billedQty;

  /// The unit billed quantity is expressed in, e.g. `ft` or `sqft`.
  final String billedUnit;

  /// True when [rule]'s minimum quantity lifted the billed quantity.
  /// Shown on the line, or the customer queries it.
  final bool minQtyApplied;

  /// The rate before any tier substitution. Printed on the quote.
  final int standardRateSen;

  /// The rate actually applied, after MVP.
  final int rateSen;

  /// How many identical windows this line covers.
  final int quantity;

  /// The line total, rounded once.
  final Money total;

  const PricedLine({
    required this.rule,
    required this.stage,
    required this.rawQty,
    required this.billedQty,
    required this.billedUnit,
    required this.minQtyApplied,
    required this.standardRateSen,
    required this.rateSen,
    required this.quantity,
    required this.total,
  });

  /// The deposit category this line's rate hold would belong to.
  DepositCategory get depositCategory => depositCategoryOf(rule.family);

  /// True when a tier rate replaced the standard one.
  bool get tierRateApplied => rateSen != standardRateSen;
}

/// A request to price one line.
class LineRequest {
  final String variant;
  final String? materialKey;
  final Layer layer;
  final Fulfilment fulfilment;
  final Length width;
  final Length? height;

  /// Identical windows priced together. Multiplies **after** the line rounds.
  final int quantity;

  const LineRequest({
    required this.variant,
    required this.width,
    this.materialKey,
    this.layer = Layer.single,
    this.fulfilment = Fulfilment.supplyInstall,
    this.height,
    this.quantity = 1,
  });
}

/// Prices one line. SPEC.md §4.3.
///
/// **Height selects the band. Height never multiplies.** For `per_ft_width`
/// only width is charged — the single most likely thing to get wrong.
PricedLine priceLine({
  required LineRequest request,
  required RateCard card,
  required PricingStage stage,
  CustomerTier tier = CustomerTier.standard,
}) {
  if (request.quantity < 1) {
    throw ArgumentError.value(request.quantity, 'quantity', 'must be at least 1');
  }

  // 1. Candidate rules for this exact product.
  final candidates = card.rules
      .where(
        (r) =>
            r.variant == request.variant &&
            r.materialKey == request.materialKey &&
            r.layer == request.layer &&
            r.fulfilment == request.fulfilment,
      )
      .toList(growable: false);

  if (candidates.isEmpty) {
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: request.materialKey,
      bandValue: null,
      detail: 'no rule matches this variant, layer and fulfilment',
    );
  }

  // 2. Select the band. Never pick the cheapest on a miss.
  final rule = _selectBand(candidates, request);

  // 3. Raw quantity by basis, exact.
  final rawQty = _rawQuantity(rule, request);

  // 4. Wastage. Not on the Phase 1 card; the step exists so the Python engine
  //    mirrors the same ordering when flooring and wallpaper arrive.

  // 5. Minimum billed quantity, BEFORE the rate multiplies.
  final minQty = rule.minQty;
  final afterMin = minQty == null ? rawQty : rawQty.max(minQty);
  final minQtyApplied = minQty != null && afterMin != rawQty;

  // 5b. Stage rounding. A quotation rounds up to a whole unit (A10); final
  //     pricing bills the measured quantity exactly (A11).
  final billedQty = switch (stage) {
    PricingStage.estimate => Rational.fromInt(afterMin.ceilToInt()),
    PricingStage.finalPricing => afterMin,
  };

  // 6. Tier rate. MVP is a flat substitute, never a percentage.
  final rateSen = rule.rateForTier(tier);

  // 7. Promo discount is Phase 2 — blocked on A4. Deliberately absent rather
  //    than guessed; see SPEC.md §13.

  // 8. One rounding, at the line total, then multiply by identical windows.
  final perWindow = Money.roundFrom(billedQty * Rational.fromInt(rateSen));
  final total = perWindow * request.quantity;

  return PricedLine(
    rule: rule,
    stage: stage,
    rawQty: rawQty,
    billedQty: billedQty,
    billedUnit: rule.basis.unit,
    minQtyApplied: minQtyApplied,
    standardRateSen: rule.rateSen,
    rateSen: rateSen,
    quantity: request.quantity,
    total: total,
  );
}

PricingRule _selectBand(List<PricingRule> candidates, LineRequest request) {
  final bandField = candidates.first.bandField;

  if (bandField == BandField.none) {
    if (candidates.length != 1) {
      throw NoApplicableRate(
        variant: request.variant,
        materialKey: request.materialKey,
        bandValue: null,
        detail:
            '${candidates.length} unbanded rules match; the card is ambiguous',
      );
    }
    return candidates.single;
  }

  final value = switch (bandField) {
    BandField.height => request.height,
    BandField.width => request.width,
    BandField.none => null,
  };

  if (value == null) {
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: request.materialKey,
      bandValue: null,
      detail: 'this product is banded by ${bandField.wire}, which was not given',
    );
  }

  final matches = candidates.where((r) => r.bandContains(value)).toList();
  if (matches.isEmpty) {
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: request.materialKey,
      bandValue: value,
      detail:
          'no band covers ${value.mm}mm — a gap in the rate card, not a price',
    );
  }
  if (matches.length > 1) {
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: request.materialKey,
      bandValue: value,
      detail:
          '${matches.length} bands overlap at ${value.mm}mm; the card is ambiguous',
    );
  }
  return matches.single;
}

Rational _rawQuantity(PricingRule rule, LineRequest request) {
  switch (rule.basis) {
    case PriceBasis.perFtWidth:
      return request.width.feetExact;

    case PriceBasis.perSqft:
      final height = request.height;
      if (height == null) {
        throw NoApplicableRate(
          variant: request.variant,
          materialKey: request.materialKey,
          bandValue: null,
          detail: 'per_sqft needs a height',
        );
      }
      return areaSqft(request.width, height);

    case PriceBasis.perMLength:
      return Rational(request.width.tmm, 10000);

    case PriceBasis.perPiece:
    case PriceBasis.perSet:
      return Rational.one;

    case PriceBasis.perRoll:
      throw UnimplementedError(
        'per_roll arrives with wallpaper in Phase 2, blocked on A7 (pattern '
        'repeat wastage) and A2b',
      );
  }
}

/// A quote's totals, broken down the way the deposit works.
class QuoteTotals {
  /// Subtotals per deposit category, before the RM300 floor.
  final Map<DepositCategory, Money> categorySubtotals;

  /// The uplift the RM300 floor added to each category, if any.
  ///
  /// Shown as its own labelled row. Never folded into the line totals —
  /// quietly inflating lines to reach RM300 is the dishonesty the
  /// reference-price disclaimer exists to prevent.
  final Map<DepositCategory, Money> categoryFloorUplift;

  /// The amount actually quoted, floors included.
  final Money total;

  const QuoteTotals({
    required this.categorySubtotals,
    required this.categoryFloorUplift,
    required this.total,
  });

  /// True when any category was lifted to the deposit minimum.
  bool get anyFloorApplied =>
      categoryFloorUplift.values.any((m) => !m.isZero);
}

/// Totals a set of priced lines, applying the RM300 per-category floor.
///
/// SPEC.md §4.3: the floor is an **order-level** step and applies to the
/// quotation only. A customer quoted RM250 who pays a RM300 deposit has
/// overpaid, and will argue about it at measurement.
QuoteTotals totalQuote({
  required List<PricedLine> lines,
  required RateCard card,
  required PricingStage stage,
}) {
  final subtotals = <DepositCategory, Money>{};
  for (final line in lines) {
    final cat = line.depositCategory;
    subtotals[cat] = (subtotals[cat] ?? Money.zero) + line.total;
  }

  final uplift = <DepositCategory, Money>{};
  var total = Money.zero;
  final floor = Money.sen(card.config.minDepositSen);

  for (final entry in subtotals.entries) {
    final raw = entry.value;
    final floored = stage == PricingStage.estimate ? raw.max(floor) : raw;
    uplift[entry.key] = floored - raw;
    total = total + floored;
  }

  return QuoteTotals(
    categorySubtotals: subtotals,
    categoryFloorUplift: uplift,
    total: total,
  );
}

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

/// Thrown when a line breaches a constraint that is not a price.
///
/// Distinct from [NoApplicableRate]: the rate card is fine, the order is not.
/// It carries the rule so the UI can show the message in the reader's language
/// rather than an English string baked in here.
class ProductRuleViolation implements Exception {
  final ProductRule rule;
  final Length actual;

  ProductRuleViolation({required this.rule, required this.actual});

  @override
  String toString() =>
      'ProductRuleViolation: ${rule.variant} ${rule.kind} '
      '${rule.dimension} ${rule.valueTmm} — got ${actual.tmm}';
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

  /// True when the customer has not chosen a material yet and this line was
  /// priced at the **dearest** option in the group.
  ///
  /// At a fair the job is to lock the deposit, not to settle every detail, so
  /// material is chosen at measurement. Quoting the dearest option is the only
  /// choice that keeps the promise in SPEC.md §8.5 — the final price can then
  /// only stay the same or fall. Quoting the cheapest would make the final go
  /// **up**, which is exactly what the disclaimer says cannot happen.
  final bool materialDeferred;

  /// The material options that were available when [materialDeferred] is true,
  /// so the line can show what still has to be picked.
  final List<String> materialOptions;

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
    this.materialDeferred = false,
    this.materialOptions = const [],
  });

  /// The deposit category this line's rate hold would belong to.
  DepositCategory get depositCategory => rule.depositCategory;

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
    throw ArgumentError.value(
      request.quantity,
      'quantity',
      'must be at least 1',
    );
  }

  // 0. Constraints that are not prices. A 25ft ZIP blind is not a wrong price,
  //    it is an order that cannot be fulfilled, and finding that out at
  //    installation is far more expensive than finding it out here.
  _checkProductRules(card, request);

  // 1. Candidate rules for this product, before material.
  var candidates = card.rules
      .where(
        (r) =>
            r.variant == request.variant &&
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

  // 2. Material, if the customer has chosen one.
  final availableMaterials = <String>{
    for (final r in candidates)
      if (r.materialKey != null) r.materialKey!,
  }..toList();

  if (request.materialKey != null) {
    candidates = candidates
        .where((r) => r.materialKey == request.materialKey)
        .toList(growable: false);
    if (candidates.isEmpty) {
      throw NoApplicableRate(
        variant: request.variant,
        materialKey: request.materialKey,
        bandValue: null,
        detail:
            'no rule for that material — available: '
            '${availableMaterials.join(", ")}',
      );
    }
  }

  // 3. Select the band. Never pick the cheapest on a miss.
  final banded = _selectBandCandidates(candidates, request);

  // 4. Resolve a still-unchosen material.
  final (rule, materialDeferred) = _resolveMaterial(
    banded,
    request,
    stage,
    availableMaterials,
  );

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
    materialDeferred: materialDeferred,
    materialOptions: materialDeferred
        ? (availableMaterials.toList()..sort())
        : const [],
  );
}

/// Narrows candidates to those whose band covers the relevant dimension.
///
/// Returns a list rather than a single rule, because several materials may
/// share one band. Never falls back to the cheapest on a miss — §4.3 step 2.
List<PricingRule> _selectBandCandidates(
  List<PricingRule> candidates,
  LineRequest request,
) {
  final bandField = candidates.first.bandField;
  if (bandField == BandField.none) return candidates;

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
      detail:
          'this product is banded by ${bandField.wire}, which was not given',
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
  return matches;
}

/// Picks the final rule, resolving a material the customer has not chosen yet.
///
/// Returns the rule and whether the material was deferred.
(PricingRule, bool) _resolveMaterial(
  List<PricingRule> candidates,
  LineRequest request,
  PricingStage stage,
  Set<String> availableMaterials,
) {
  if (candidates.length == 1) return (candidates.single, false);

  final distinctMaterials = <String?>{
    for (final r in candidates) r.materialKey,
  };

  if (distinctMaterials.length != candidates.length) {
    // Rules that match but do not differ only by material mean the card itself
    // is ambiguous. Choosing between them would be inventing a price.
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: request.materialKey,
      bandValue: null,
      detail:
          '${candidates.length} rules match and they do not differ only by '
          'material; the card is ambiguous',
    );
  }

  // Final pricing happens with the customer's actual choice in hand. Guessing
  // there would put a number on an invoice nobody chose.
  if (stage == PricingStage.finalPricing) {
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: null,
      bandValue: null,
      detail:
          'material must be chosen before final pricing — one of '
          '${availableMaterials.join(", ")}',
    );
  }

  // Quote the dearest option, so the final can only stay level or fall.
  final dearest = candidates.reduce((a, b) => b.rateSen > a.rateSen ? b : a);
  return (dearest, true);
}

/// Enforces the constraints that are not prices.
///
/// A 25ft ZIP blind is not a wrong price, it is an order that cannot be
/// fulfilled — and discovering that at installation costs far more than
/// discovering it here.
void _checkProductRules(RateCard card, LineRequest request) {
  for (final rule in card.productRules) {
    if (rule.variant != request.variant) continue;
    final limit = rule.valueTmm;
    if (limit == null) continue;

    final value = switch (rule.dimension) {
      'width' => request.width,
      'height' => request.height,
      _ => null,
    };
    if (value == null) continue;

    final breached = switch (rule.kind) {
      'max_dimension' => value.tmm > limit,
      'min_dimension' => value.tmm < limit,
      _ => false,
    };
    if (breached) throw ProductRuleViolation(rule: rule, actual: value);
  }
  // `requires` and `excludes` need the whole order rather than one line, so
  // they are checked when the quote is totalled. Phase 2.
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
      final height = request.height;
      final coverage = rule.coverageSqft;
      if (height == null || coverage == null || coverage.isZero) {
        throw NoApplicableRate(
          variant: request.variant,
          materialKey: request.materialKey,
          bandValue: null,
          detail: 'per_roll needs a height and a coverage_sqft on the rule',
        );
      }
      // `coverage_sqft` is the area ONE CHARGE covers, not the area one roll
      // covers. `bundle_qty` records how many rolls that charge delivers and
      // deliberately does NOT divide here — dividing twice would halve the
      // quote.
      //
      // For the Korea wallpaper: RM800 buys two rolls of 14ft x 10ft, so one
      // charge covers 280sqft (A14, answered). The ceiling then rounds up to
      // whole bundles, because a buy-one-free-one pair cannot be split.
      //
      // Pattern-repeat wastage is NOT applied: §13 A7 asks whether it is
      // already absorbed in the roll price, and a guessed percentage would
      // silently overcharge on every wall.
      return areaSqft(request.width, height) / coverage;
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
  bool get anyFloorApplied => categoryFloorUplift.values.any((m) => !m.isZero);
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

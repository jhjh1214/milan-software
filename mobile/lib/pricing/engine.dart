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

  /// True when this line HAD a printed minimum and it was stood down because
  /// the job cleared the threshold. §13 A21.
  ///
  /// Distinct from `!minQtyApplied`, which is also true for a line that simply
  /// measured above its minimum, and for a line that never had one. This is
  /// the reason a line came in below its printed rate, and both the revised
  /// order document and the variance report need to be able to say it.
  final bool minQtyWaived;

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
    this.minQtyWaived = false,
    required this.standardRateSen,
    required this.rateSen,
    required this.quantity,
    required this.total,
    this.materialDeferred = false,
    this.materialOptions = const [],
    this.parentFamily,
  });

  /// The family of the line this one hangs off, when it hangs off one.
  final Family? parentFamily;

  /// The deposit category this line's rate hold would belong to.
  ///
  /// An add-on takes its **parent's** category. A rule that names one outright
  /// still wins — a flooring service belongs to the work it prepares — and a
  /// parentless add-on raises rather than guessing (hard rule 6).
  DepositCategory get depositCategory =>
      rule.depositCategoryOverride ??
      depositCategoryOf(rule.family, parentFamily: parentFamily);

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

  /// The family of the line this one hangs off, when it hangs off one.
  ///
  /// An add-on has no deposit category of its own: a motor is charged on top
  /// of the curtain it drives, and dismantling an old floor belongs to the
  /// floor going over it. Without this the category cannot be decided, and
  /// `depositCategoryOf` raises rather than guessing — which is right, because
  /// hard rule 6 makes filing a flooring line under a curtain lock the
  /// expensive bug in this design.
  ///
  /// Null for a line that starts its own window, which is most of them.
  final Family? parentFamily;

  const LineRequest({
    required this.variant,
    required this.width,
    this.materialKey,
    this.layer = Layer.single,
    this.fulfilment = Fulfilment.supplyInstall,
    this.height,
    this.quantity = 1,
    this.parentFamily,
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

  // 4b. A row whose price is still a placeholder is not a price.
  //
  // Stairs and landings exist on the card before their rates do, so the shape
  // is ready when the numbers arrive. Quoting the placeholder would put RM0 —
  // or whatever was typed to hold the slot — in front of a customer, which is
  // worse than not offering the product yet. Refused loudly, and the screen
  // already has the right words for it: "no complete rate, tell the office".
  if (rule.provisional) {
    throw NoApplicableRate(
      variant: request.variant,
      materialKey: request.materialKey,
      bandValue: null,
      detail:
          '${rule.id} has no rate yet — the row is a placeholder and cannot '
          'be quoted until a real price is published',
    );
  }

  // 3. Raw quantity by basis, exact.
  final rawQty = _rawQuantity(rule, request, stage);

  // 4. Wastage. Not on the Phase 1 card; the step exists so the Python engine
  //    mirrors the same ordering when flooring and wallpaper arrive.

  // 5. Minimum billed quantity, BEFORE the rate multiplies. §13 A21.
  //
  // **Quotation only.** The printed "min 18 sqft" is a commercial floor on a
  // quotation, and at final pricing it is replaced by the RM300 per-category
  // deposit floor that `totalQuote` and `repriceOrder` apply.
  //
  // Applying it at both stages produced an inversion the client rejected: a
  // 12 sqft timber blind billed RM360 (its printed 18 sqft) while a LARGER
  // 15 sqft one billed RM300. A smaller window costing more is not a rule
  // anybody can explain at a counter. Billing the exact tape and flooring the
  // job at RM300 is monotonic by construction — a bigger window can never
  // come out cheaper than a smaller one.
  //
  // Per WINDOW, not per line: three identical small blinds each meet the
  // minimum separately on the quotation, then step 8 multiplies.
  final minQty = stage == PricingStage.estimate ? rule.minQty : null;
  final afterMin = minQty == null ? rawQty : rawQty.max(minQty);
  final minQtyApplied = minQty != null && afterMin != rawQty;

  // True when this line HAD a printed minimum and final pricing did not apply
  // it. The revised order document and the variance report both need to say
  // WHY a line came in below its printed rate.
  final minQtyWaived =
      stage == PricingStage.finalPricing &&
      rule.minQty != null &&
      rawQty < rule.minQty!;

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
    minQtyWaived: minQtyWaived,
    standardRateSen: rule.rateSen,
    rateSen: rateSen,
    quantity: request.quantity,
    total: total,
    materialDeferred: materialDeferred,
    materialOptions: materialDeferred
        ? (availableMaterials.toList()..sort())
        : const [],
    parentFamily: request.parentFamily,
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
  // they are checked by [checkOrderRules].
}

/// A `requires` or `excludes` rule the quote as a whole breaks.
///
/// Distinct from [ProductRuleViolation], which a single line can raise: this
/// one only exists in the context of the other lines. Herringbone SPC needs
/// self levelling, and an intermediate joint needs a motor — neither is
/// knowable from the line alone.
class OrderRuleViolation {
  final ProductRule rule;

  /// The variant that triggered the rule.
  final String variant;

  const OrderRuleViolation({required this.rule, required this.variant});
}

/// Checks the rules that only make sense across a whole quote.
///
/// Returned rather than thrown. A missing self levelling is not a reason to
/// refuse the quote — it is a reason to tell the salesperson to add a line,
/// while the customer is still standing there. Refusing would lose the sale;
/// staying silent would lose the floor.
List<OrderRuleViolation> checkOrderRules({
  required List<PricedLine> lines,
  required RateCard card,
}) {
  final present = {for (final l in lines) l.rule.variant};
  final out = <OrderRuleViolation>[];

  for (final rule in card.productRules) {
    if (!present.contains(rule.variant)) continue;
    final target = rule.target;
    if (target == null) continue;

    final breached = switch (rule.kind) {
      'requires' => !present.contains(target),
      'excludes' => present.contains(target),
      _ => false,
    };
    if (breached) {
      out.add(OrderRuleViolation(rule: rule, variant: rule.variant));
    }
  }
  return out;
}

Rational _rawQuantity(
  PricingRule rule,
  LineRequest request,
  PricingStage stage,
) {
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
      if (coverage == null || coverage.isZero) {
        throw NoApplicableRate(
          variant: request.variant,
          materialKey: request.materialKey,
          bandValue: null,
          detail: 'per_roll needs a coverage_sqft on the rule',
        );
      }
      // §13 A25: at the fair the wall does not have to be measured at all —
      // "normally just do one set of two rolls". No height means no
      // measurement was offered, and the default is exactly one pack. At
      // final pricing the site has been measured, so the same silence would
      // hide a wall nobody actually looked at — refuse instead, same as
      // every other basis missing its final dimension.
      if (height == null) {
        if (stage == PricingStage.estimate) return Rational.one;
        throw NoApplicableRate(
          variant: request.variant,
          materialKey: request.materialKey,
          bandValue: null,
          detail: 'per_roll needs a height at final pricing',
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

  /// The order-level delivery charge, when the address is outside Melaka.
  ///
  /// Driven by the address rather than by any line, and shown on its own row
  /// **before** the total — §4.1 is explicit that it must never appear after
  /// the customer has already agreed a number.
  final DeliveryZone? deliveryZone;
  final Money deliveryCharge;

  /// The amount actually quoted: floors and delivery included.
  final Money total;

  const QuoteTotals({
    required this.categorySubtotals,
    required this.categoryFloorUplift,
    required this.total,
    this.deliveryZone,
    this.deliveryCharge = Money.zero,
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
  String? deliveryZoneId,
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
    // Both stages, since §13 A21d. It used to be the estimate's alone, on the
    // reasoning that a final is exact — but a final that came in under the
    // RM300 already deposited is a bill the customer has overpaid, which is
    // the same complaint §8.4 exists to prevent one document earlier.
    //
    // It is also what replaces `min_qty` at final pricing, and what keeps the
    // arithmetic monotonic: flat at RM300 below the floor, the exact tape
    // above it, so a billed total never falls as a window grows.
    final floored = raw.max(floor);
    uplift[entry.key] = floored - raw;
    total = total + floored;
  }

  // The delivery charge is order-level and sits outside the deposit
  // categories: it is travel, not product, so it must not be dragged up to
  // RM300 by a category floor.
  final zone = deliveryZoneId == null
      ? null
      : card.deliveryZones.where((z) => z.id == deliveryZoneId).firstOrNull;
  final delivery = zone == null ? Money.zero : Money.sen(zone.chargeSen);

  return QuoteTotals(
    categorySubtotals: subtotals,
    categoryFloorUplift: uplift,
    deliveryZone: zone,
    deliveryCharge: delivery,
    total: total + delivery,
  );
}

/// Repricing a measured order. SPEC.md §11 Phase 6, §6.1, §8.5.
///
/// > A measured order reprices at the old card even after two rate publishes
///
/// That is the phase's first acceptance criterion and the reason a rate lock is
/// worth RM300 to a customer. Every line here prices at the card version and
/// discount **it recorded when it was quoted** — never at the active card, and
/// never at the order's pinned version, because a line's lock is its own
/// (§6.1: applying a curtain lock to a flooring line is the expensive bug in
/// this design).
///
/// **Quantity is exact.** The quote rounded every quantity up to a whole unit;
/// the bill does not. That asymmetry is the product, not an artefact, and it is
/// what makes the estimate a ceiling the final can only fall below.
///
/// **Nothing falls back.** A line the tape has not reached, a material nobody
/// chose, or a card version not to hand refuses and says which. Every fallback
/// would be a number on an invoice nobody can explain a year later — and the
/// one fallback that looks most reasonable, using today's card when the held
/// one is missing, is precisely what the deposit was taken to prevent.
///
/// **A refused line stops the order total, not just its own.** An order total
/// that quietly excluded a line would be a balance somebody collects and a
/// window nobody bills for.
///
/// Pure. No Flutter, no I/O, no clock.
library;

import '../core/length.dart';
import '../core/money.dart';
import '../core/rational.dart';
import 'engine.dart';
import 'models.dart';

/// Why one line could not be finally priced.
enum FinalPricingRefusal {
  /// No tape has been taken to it. Five of six windows measured is not a
  /// measured order.
  notMeasured('not_measured'),

  /// Quoted at the dearest option in its group (§13 B7) and still unchosen.
  /// Nobody is invoiced for a material they never picked.
  materialNotChosen('material_not_chosen'),

  /// The card version this line recorded is not among those supplied. Using
  /// another one would silently reprice a held order.
  cardUnavailable('card_unavailable'),

  /// The card was found and could not price the line — a variant withdrawn, a
  /// band that no longer covers the measured drop. Reported rather than
  /// thrown, so one impossible line does not lose the other five.
  noApplicableRate('no_applicable_rate');

  const FinalPricingRefusal(this.wire);

  final String wire;

  static FinalPricingRefusal fromWire(String wire) =>
      FinalPricingRefusal.values.firstWhere((r) => r.wire == wire);
}

/// One line as it stood when the measurer arrived.
class MeasuredLine {
  const MeasuredLine({
    required this.id,
    required this.variant,
    required this.estimateTotal,
    required this.appliedRateCardVersion,
    this.materialKey,
    this.layer = Layer.single,
    this.fulfilment = Fulfilment.supplyInstall,
    this.quantity = 1,
    this.finalWidth,
    this.finalHeight,
    this.materialDeferred = false,
  });

  final String id;
  final String variant;
  final String? materialKey;
  final Layer layer;
  final Fulfilment fulfilment;
  final int quantity;

  /// What the quotation charged. Kept beside the final rather than replaced by
  /// it, so §6.3's variance report has both to compare.
  final Money estimateTotal;

  /// The version this line was priced at. **This** is what reprices it.
  final int appliedRateCardVersion;

  /// The tape. Null until somebody has taken it.
  final Length? finalWidth;
  final Length? finalHeight;

  /// True while the line is still carrying the dearest option in its group.
  final bool materialDeferred;

  bool get isMeasured => finalWidth != null;
}

/// One line after measurement.
class FinalLine {
  const FinalLine({
    required this.id,
    required this.estimateTotal,
    this.pricedAtVersion,
    this.priced,
    this.refusal,
  });

  final String id;
  final Money estimateTotal;

  /// The card version this actually priced at, null when it refused.
  final int? pricedAtVersion;

  final PricedLine? priced;
  final FinalPricingRefusal? refusal;

  Money? get finalTotal => priced?.total;

  /// `final − estimate`. Negative is the expected direction: the quote rounds
  /// every quantity up and the bill does not.
  Money? get variance {
    final total = finalTotal;
    return total == null ? null : total - estimateTotal;
  }

  /// The window is genuinely bigger than the customer said at the fair.
  ///
  /// §8.5's promise is about rounding, not about the customer's own wrong
  /// dimensions, so this is flagged rather than refused — refusing would block
  /// a real order. §6.3's variance report counts these separately instead of
  /// averaging them away.
  bool get isOverEstimate {
    final v = variance;
    return v != null && v.sen > 0;
  }
}

/// A whole order after site measurement.
class FinalPricing {
  const FinalPricing({
    required this.lines,
    required this.estimateTotal,
    required this.finalTotal,
    required this.isComplete,
    this.minQtyWaived = false,
    this.exactSubtotal,
    this.categoryFloorUplift = Money.zero,
  });

  final List<FinalLine> lines;

  /// True when the job cleared the threshold and every printed minimum was
  /// stood down. §13 A21.
  final bool minQtyWaived;

  /// What the lines came to with no minimum applied — the number the waiver
  /// decision was actually made on (A21b). Null until the order fully prices.
  ///
  /// Kept because a rule that turns on a comparison is unreadable without the
  /// figure it compared: "RM324, which cleared RM300" is a sentence somebody
  /// can check, and "the minimums were waived" is not.
  final Money? exactSubtotal;

  /// What §8.4's per-category deposit floor added on top of the lines. A21d.
  ///
  /// An order-level number, deliberately not pushed back into the lines: a
  /// line has to keep saying what its own product cost, or the variance report
  /// compares an estimate against a figure that was never a price.
  final Money categoryFloorUplift;

  final Money estimateTotal;

  /// Null until every line has priced. An order total that quietly excluded a
  /// line would be a balance somebody collects and a window nobody bills for.
  final Money? finalTotal;

  /// True when every line priced, and there was at least one.
  final bool isComplete;

  Money? get variance {
    final total = finalTotal;
    return total == null ? null : total - estimateTotal;
  }

  /// The lines that could not be priced, in order. What the measurer still has
  /// to do before they leave the house.
  List<FinalLine> get outstanding =>
      lines.where((l) => l.refusal != null).toList(growable: false);

  /// Lines whose tape came in above the estimate. §8.5 says this cannot be a
  /// rounding artefact, so each one is a real discrepancy worth a conversation.
  List<FinalLine> get overEstimate =>
      lines.where((l) => l.isOverEstimate).toList(growable: false);
}

/// Reprices a measured order. SPEC.md §11 Phase 6.
///
/// [cards] is keyed by version and holds every published card the caller has.
/// A line whose version is missing refuses; it is never priced at another.
FinalPricing repriceOrder({
  required List<MeasuredLine> lines,
  required Map<int, RateCard> cards,
  CustomerTier tier = CustomerTier.standard,
}) {
  // §13 A21, in the order the answer fixes — and the order matters.
  //
  // Pass 1 prices every line from the tape with NO minimum, which gives the
  // exact subtotal. Pass 2 decides. The threshold is measured against the
  // exact prices and never against the minimum-applied ones (A21b): the other
  // reading is circular, because the minimums are what the decision produces.
  final exact = [
    for (final line in lines)
      _repriceLine(line, cards, tier, applyMinQty: false),
  ];

  // A21a: the WHOLE order, not the deposit category. A house of curtains and
  // one small blind is one job, and the blind rides along with it.
  //
  // Only lines that actually priced contribute. A refused line has no number,
  // and treating a missing one as zero would drag a job under the threshold
  // and bill minimums the customer should not have paid — which is the same
  // failure as a total that quietly excluded a window, one step earlier.
  final exactSubtotal = exact.fold<Money>(
    Money.zero,
    (sum, line) => sum + (line.finalTotal ?? Money.zero),
  );

  // The threshold is config on the card, and every line's card may differ.
  // Taking the LOWEST of them is the customer-favourable reading, and the
  // only one that does not depend on which line happens to be first.
  final threshold = _waiverThreshold(lines, cards);

  // A21c: exactly the threshold clears it. RM300 is also the deposit figure,
  // so an order landing on it is the common case rather than a corner one.
  final everyLinePriced =
      exact.isNotEmpty && exact.every((l) => l.refusal == null);
  final waived =
      everyLinePriced &&
      threshold != null &&
      exactSubtotal.sen >= threshold.sen;

  final priced = waived
      ? exact
      : [
          for (final line in lines)
            _repriceLine(line, cards, tier, applyMinQty: true),
        ];

  // An order with no lines has not been priced. Zero is a total somebody could
  // act on, and "RM0.00 due" is a worse answer than "not priced".
  final complete = priced.isNotEmpty && priced.every((l) => l.refusal == null);

  final uplift = complete
      ? _categoryFloorUplift(priced, lines, cards, (l) => l.finalTotal!)
      : Money.zero;
  final estimateUplift = complete
      ? _categoryFloorUplift(priced, lines, cards, (l) => l.estimateTotal)
      : Money.zero;

  final estimate =
      priced.fold<Money>(Money.zero, (sum, line) => sum + line.estimateTotal) +
      estimateUplift;

  return FinalPricing(
    lines: priced,
    minQtyWaived: waived,
    exactSubtotal: complete ? exactSubtotal : null,
    categoryFloorUplift: uplift,
    estimateTotal: estimate,
    // The lines, plus whatever the per-category deposit floor added on top.
    // The uplift stays an order-level number rather than being smeared back
    // across the lines: a line has to keep saying what its own product cost,
    // or the variance report is comparing an estimate against a figure that
    // was never a price for anything.
    finalTotal: complete
        ? priced.fold<Money>(
                Money.zero,
                (sum, line) => sum + line.finalTotal!,
              ) +
              uplift
        : null,
    isComplete: complete,
  );
}

/// The lowest waiver threshold among the cards this order's lines priced at.
///
/// Lines can sit on different card versions — a lock is per line — and those
/// cards can carry different config. The lowest is the customer-favourable
/// reading and the only one that does not depend on line order. Null when no
/// line could name its card, in which case nothing is waived.
Money? _waiverThreshold(List<MeasuredLine> lines, Map<int, RateCard> cards) {
  Money? lowest;
  for (final line in lines) {
    final card = cards[line.appliedRateCardVersion];
    if (card == null) continue;
    final value = card.config.minQtyWaiver;
    if (lowest == null || value.sen < lowest.sen) lowest = value;
  }
  return lowest;
}

/// §8.4's per-category deposit floor, now applied at final pricing too.
///
/// §13 A21d: waiving a minimum can drop a final below the deposit the customer
/// already handed over, and the answer is that it never bills below it. Same
/// rule as the quotation, so the two documents cannot contradict each other —
/// and §8.5's promise survives, because a quote that was itself floored to
/// RM300 is met exactly rather than undercut.
///
/// Returns the total uplift across every category, in sen.
/// [amountOf] selects which figure to floor. It is run over BOTH the final and
/// the estimate: the quotation the customer holds already had this floor
/// applied (§8.4), but only as an order-level uplift, so a sum of the recorded
/// line estimates is short by it. Flooring only the final would then make every
/// small order look like its price went **up** — the one thing §8.5 says cannot
/// happen, invented by the arithmetic rather than by anything real.
Money _categoryFloorUplift(
  List<FinalLine> priced,
  List<MeasuredLine> lines,
  Map<int, RateCard> cards,
  Money Function(FinalLine) amountOf,
) {
  final subtotals = <DepositCategory, Money>{};
  final floors = <DepositCategory, Money>{};

  for (final line in priced) {
    final rule = line.priced?.rule;
    if (rule == null) continue;

    // An unparented add-on has no deposit category, and `depositCategory`
    // throws rather than guessing one — correctly, because filing it under
    // curtains could price it at a held rate its RM300 never bought.
    //
    // It is skipped for FLOORING only, and its total still counts in the
    // order. No category means no deposit was ever taken against it, so it
    // cannot pull a category under a floor and must not invent one. The
    // quotation raises the same data problem out loud (`totalQuote`); final
    // pricing must not newly crash on an order that was priceable a minute
    // ago, in a house, with a measurer holding the phone.
    final DepositCategory cat;
    try {
      cat = rule.depositCategory;
    } on UnknownDepositCategory {
      continue;
    }

    subtotals[cat] = (subtotals[cat] ?? Money.zero) + amountOf(line);

    // The floor comes off the card that priced the line, like every other
    // configured figure — never off today's active card.
    final version = line.pricedAtVersion;
    final card = version == null ? null : cards[version];
    if (card == null) continue;
    final floor = Money.sen(card.config.minDepositSen);
    final known = floors[cat];
    // Lowest again, for the same reason as the waiver threshold.
    if (known == null || floor.sen < known.sen) floors[cat] = floor;
  }

  var uplift = Money.zero;
  for (final entry in subtotals.entries) {
    final floor = floors[entry.key];
    if (floor == null) continue;
    if (entry.value.sen < floor.sen) {
      uplift = uplift + (floor - entry.value);
    }
  }
  return uplift;
}

FinalLine _repriceLine(
  MeasuredLine line,
  Map<int, RateCard> cards,
  CustomerTier tier, {
  required bool applyMinQty,
}) {
  FinalLine refuse(FinalPricingRefusal why) =>
      FinalLine(id: line.id, estimateTotal: line.estimateTotal, refusal: why);

  if (!line.isMeasured) return refuse(FinalPricingRefusal.notMeasured);

  // Checked before the card is looked up, so a line whose material nobody
  // chose says so even when the card is also missing. The material is the one
  // the measurer can fix while standing in the house.
  if (line.materialDeferred && line.materialKey == null) {
    return refuse(FinalPricingRefusal.materialNotChosen);
  }

  final card = cards[line.appliedRateCardVersion];
  if (card == null) return refuse(FinalPricingRefusal.cardUnavailable);

  try {
    final result = priceLine(
      request: LineRequest(
        variant: line.variant,
        materialKey: line.materialKey,
        layer: line.layer,
        fulfilment: line.fulfilment,
        width: line.finalWidth!,
        height: line.finalHeight,
        quantity: line.quantity,
      ),
      card: card,
      stage: PricingStage.finalPricing,
      tier: tier,
      applyMinQty: applyMinQty,
    );

    return FinalLine(
      id: line.id,
      estimateTotal: line.estimateTotal,
      pricedAtVersion: line.appliedRateCardVersion,
      priced: result,
    );
  } on NoApplicableRate {
    // One line that cannot be priced must not lose the other five. The
    // measurer needs to know which window is the problem, in the house.
    return refuse(FinalPricingRefusal.noApplicableRate);
  }
}

/// The exact quantity a final line bills, for a screen that shows its working.
///
/// Exposed because §11 Phase 6 wants the variance visible to the measurer
/// before they leave the house, and "12ft quoted, 11.48ft measured" is the
/// sentence that explains the number.
Rational? billedQuantityOf(FinalLine line) => line.priced?.billedQty;

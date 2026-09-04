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
  });

  final List<FinalLine> lines;

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
  final priced = [for (final line in lines) _repriceLine(line, cards, tier)];

  final estimate = priced.fold<Money>(
    Money.zero,
    (sum, line) => sum + line.estimateTotal,
  );

  // An order with no lines has not been priced. Zero is a total somebody could
  // act on, and "RM0.00 due" is a worse answer than "not priced".
  final complete = priced.isNotEmpty && priced.every((l) => l.refusal == null);

  return FinalPricing(
    lines: priced,
    estimateTotal: estimate,
    finalTotal: complete
        ? priced.fold<Money>(Money.zero, (sum, line) => sum + line.finalTotal!)
        : null,
    isComplete: complete,
  );
}

FinalLine _repriceLine(
  MeasuredLine line,
  Map<int, RateCard> cards,
  CustomerTier tier,
) {
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

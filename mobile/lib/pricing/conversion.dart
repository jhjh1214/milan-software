/// Turning a quote into a confirmed order. SPEC.md §6.3, and §3's flow:
///
/// > customer pays RM300 minimum deposit PER PRODUCT CATEGORY
/// > → ORDER IS CONFIRMED. Not a quote, not a lead. A confirmed sale.
///
/// So the deposit is the conversion. Nothing else confirms an order, and taking
/// one is the only thing that does.
///
/// ## The quote is referenced, never consumed
///
/// Client, Sep 2026: *"the quote should be recorded as reference to the order,
/// so have rough estimate of what to do."*
///
/// The quote stays exactly as it was and the order points back at it. That is
/// what the measurement team reads before they go out — the rough estimate of
/// what the job is — and it is what §6.3's variance report compares the final
/// against. Mutating the quote into an order would destroy the estimate that
/// the comparison needs.
///
/// ## Each line snapshots what priced it
///
/// A line records its rule, band, rate and card version at the moment of
/// conversion. A year later, when a customer asks why a curtain cost RM552,
/// the answer has to be available without reconstructing which card was in
/// force that afternoon — and the card may since have been superseded twice.
///
/// Pure: no clock, no I/O, no Flutter. Everything is passed in.
library;

import '../core/length.dart';
import '../core/money.dart';
import '../core/rational.dart';
import 'engine.dart';
import 'rate_lock.dart';

/// One line as it lands on a confirmed order.
///
/// The estimate dimensions are kept for good. The final ones arrive after site
/// measurement and sit beside them, never on top of them: §6.3 keeps both so
/// the variance report can say who is guessing badly.
class OrderLineDraft {
  final String id;

  /// The quote line this came from. The trail back to the estimate.
  final String quoteLineId;

  final int sortOrder;
  final String room;
  final String variant;
  final String? materialKey;
  final String layer;
  final String? parentLineId;

  /// What was entered at the fair, in tenths of a millimetre. Null only for
  /// a room-sourced flooring line -- see [directAreaSqft].
  final Length? estWidth;
  final Length? estHeight;

  /// A pre-known area, in square feet, exact. SPEC.md's property library: a
  /// saved room's area does not reduce to one rectangle, so a room-sourced
  /// flooring line carries this instead of a width and a height.
  final Rational? directAreaSqft;
  final int quantity;

  /// The lock that priced it, or null when nothing did. §6.1: a line whose
  /// category has no active lock must never be priced at a held version, and
  /// this is the record of which one applied.
  final String? categoryLockId;

  /// How it was priced, kept so it stays explainable when the card moves on.
  final String appliedRuleId;
  final String? appliedBandLabel;
  final int appliedRateCardVersion;
  final Rational appliedDiscountPct;

  /// Before any tier substitution, and after. Both, because the quote prints
  /// the standard rate beside the MVP one.
  final int standardRateSen;
  final int rateSen;

  final String billedQty;
  final String billedUnit;
  final Money lineTotal;

  /// True when the customer has still to choose a material, and the line was
  /// quoted at the **dearest** option in its group.
  final bool materialDeferred;

  /// Where the estimate dimensions actually came from. SPEC.md Phase 8.
  /// `manual` (the default) or `project_library` — never `site_measurement`
  /// here, which is earned only through a real visit, after confirmation.
  final String measurementSource;
  final String? sourceProjectId;
  final String? sourceUnitTypeId;
  final int? sourceVersion;

  const OrderLineDraft({
    required this.id,
    required this.quoteLineId,
    required this.sortOrder,
    required this.room,
    required this.variant,
    required this.materialKey,
    required this.layer,
    required this.estWidth,
    required this.estHeight,
    this.directAreaSqft,
    required this.quantity,
    required this.appliedRuleId,
    required this.appliedRateCardVersion,
    required this.appliedDiscountPct,
    required this.standardRateSen,
    required this.rateSen,
    required this.billedQty,
    required this.billedUnit,
    required this.lineTotal,
    this.parentLineId,
    this.categoryLockId,
    this.appliedBandLabel,
    this.materialDeferred = false,
    this.measurementSource = 'manual',
    this.sourceProjectId,
    this.sourceUnitTypeId,
    this.sourceVersion,
  });

  /// Whether this line still needs a tape measure taking to it.
  ///
  /// Everything does, at conversion. §8.5 promises the final will be the same
  /// or lower, and that promise is only kept by measuring.
  bool get needsMeasuring => true;
}

/// A confirmed order, before it is written down.
class OrderDraft {
  final String id;

  /// The quote this came from. Recorded as a reference, never folded in: it is
  /// the rough estimate of what to do, and the measurement team reads it.
  final String quoteId;

  /// Where the sale happened. Decides whether the deposit locked anything.
  final Channel channel;

  /// The card the quote was priced against. A later publish must not reprice a
  /// confirmed order.
  final int pinnedRateCardVersion;

  final String? customerName;
  final String? customerPhone;
  final String? deliveryZoneId;
  final Money deliveryCharge;

  /// Where the visit is, if the customer had it at the fair (§13 C10).
  final String? siteAddress;
  final String? sitePostcode;
  final DateTime? siteReadyFrom;

  /// What the quote came to. Kept for good, beside the final, so §6.3's
  /// variance report has something to compare against.
  final Money estimateTotal;

  /// Money taken so far.
  ///
  /// **What is left is deliberately not computed here.** Client, Sep 2026:
  /// *"no need to say owe how much based on quotation, only say deposit is for
  /// fair lock price rate."* A balance derived from an estimate is a number the
  /// customer will remember and the tape will contradict, and §8.5 promises the
  /// final can only fall. The balance becomes real at final pricing, and not a
  /// moment earlier.
  final Money depositPaid;

  final List<OrderLineDraft> lines;
  final DateTime confirmedAt;

  const OrderDraft({
    required this.id,
    required this.quoteId,
    required this.channel,
    required this.pinnedRateCardVersion,
    required this.estimateTotal,
    required this.depositPaid,
    required this.lines,
    required this.confirmedAt,
    this.customerName,
    this.customerPhone,
    this.deliveryZoneId,
    this.deliveryCharge = Money.zero,
    this.siteAddress,
    this.sitePostcode,
    this.siteReadyFrom,
  });

  /// True while any line is still on estimated dimensions. Everything is, at
  /// conversion.
  bool get hasUnmeasuredLines => lines.any((l) => l.needsMeasuring);

  /// The card version every line was priced at.
  ///
  /// What the deposit actually bought: *"must have price rate at that time
  /// reference for that bill."* The final invoice is worked out from this
  /// version's rates, whatever has been published since.
  int get heldRateReference => pinnedRateCardVersion;
}

/// Why a quote cannot become an order yet.
enum ConversionRefusal {
  /// Nothing to confirm. An order with no lines is a lead, not a sale.
  noLines('no_lines'),

  /// No money has been taken. §3: the deposit **is** the confirmation, so
  /// there is no such thing as a confirmed order nobody has paid for.
  noDeposit('no_deposit'),

  /// A line the engine could not price. Confirming it would put a number on
  /// the order that nobody can explain, and the customer would be invoiced
  /// from it.
  unpricedLine('unpriced_line'),

  /// A line's lock holds one card version and the quote was priced at another.
  ///
  /// The customer is being charged a price their RM300 did not buy — in either
  /// direction. Refused rather than recorded, because writing the held version
  /// onto a line that was priced at a different one would make the order lie
  /// about itself, and that lie is what somebody would read a year later.
  heldVersionNotApplied('held_version_not_applied');

  const ConversionRefusal(this.wire);

  final String wire;
}

/// The outcome of trying to confirm a quote.
class ConversionResult {
  final OrderDraft? order;
  final ConversionRefusal? refusedBecause;

  const ConversionResult.confirmed(OrderDraft this.order)
    : refusedBecause = null;
  const ConversionResult.refused(ConversionRefusal this.refusedBecause)
    : order = null;

  bool get confirmed => order != null;
}

/// One line's inputs, as the quote holds them.
class ConvertibleLine {
  final String id;
  final int sortOrder;
  final String room;
  final String layer;
  final String? parentLineId;
  final Length? width;
  final Length? height;

  /// A pre-known area, in square feet, exact. SPEC.md's property library.
  final Rational? directAreaSqft;

  /// What the engine made of it, or null if it could not price it.
  final PricedLine? priced;

  /// The lock that decided its card and discount, if one did.
  final RateBasis basis;

  /// Where the dimensions came from. SPEC.md Phase 8. Null means typed by
  /// hand.
  final String? sourceProjectId;
  final String? sourceUnitTypeId;
  final int? sourceVersion;

  const ConvertibleLine({
    required this.id,
    required this.sortOrder,
    required this.room,
    required this.layer,
    required this.width,
    required this.height,
    required this.basis,
    this.directAreaSqft,
    this.priced,
    this.parentLineId,
    this.sourceProjectId,
    this.sourceUnitTypeId,
    this.sourceVersion,
  });
}

/// Confirms a quote as an order. SPEC.md §6.3.
///
/// [orderId] and each line's [OrderLineDraft.id] are client-generated by the
/// caller, so two part-timers offline at one fair cannot collide. The
/// human-readable `order_no` is **not** produced here: it comes from the
/// server, like a receipt number, and is shown as "pending sync" until it
/// arrives.
ConversionResult confirmQuoteAsOrder({
  required String orderId,
  required String quoteId,
  required Channel channel,
  required int pinnedRateCardVersion,
  required List<ConvertibleLine> lines,
  required Money estimateTotal,
  required Money depositPaid,
  required DateTime at,
  required String Function() newLineId,
  String? customerName,
  String? customerPhone,
  String? deliveryZoneId,
  Money deliveryCharge = Money.zero,
  String? siteAddress,
  String? sitePostcode,
  DateTime? siteReadyFrom,
}) {
  if (lines.isEmpty) {
    return const ConversionResult.refused(ConversionRefusal.noLines);
  }
  if (depositPaid.sen <= 0) {
    // §3: the deposit is the confirmation. Without one this is still a quote,
    // however finished it looks.
    return const ConversionResult.refused(ConversionRefusal.noDeposit);
  }
  if (lines.any((l) => l.priced == null)) {
    // Refused rather than confirmed with a hole. A line nobody can price is a
    // data problem, and confirming around it puts a number on an order that
    // cannot be explained to the customer it is billed to.
    return const ConversionResult.refused(ConversionRefusal.unpricedLine);
  }
  if (lines.any((l) => l.basis.rateCardVersion != pinnedRateCardVersion)) {
    // The quote on screen was priced at one version and a lock says another.
    // Whichever is right, the customer is being shown a number their RM300 did
    // not buy, and confirming would carve that into an order.
    return const ConversionResult.refused(
      ConversionRefusal.heldVersionNotApplied,
    );
  }

  return ConversionResult.confirmed(
    OrderDraft(
      id: orderId,
      quoteId: quoteId,
      channel: channel,
      pinnedRateCardVersion: pinnedRateCardVersion,
      customerName: customerName,
      customerPhone: customerPhone,
      deliveryZoneId: deliveryZoneId,
      deliveryCharge: deliveryCharge,
      siteAddress: siteAddress,
      sitePostcode: sitePostcode,
      siteReadyFrom: siteReadyFrom,
      estimateTotal: estimateTotal,
      depositPaid: depositPaid,
      confirmedAt: at,
      lines: [
        for (final line in lines)
          OrderLineDraft(
            id: newLineId(),
            quoteLineId: line.id,
            sortOrder: line.sortOrder,
            room: line.room,
            variant: line.priced!.rule.variant,
            materialKey: line.priced!.rule.materialKey,
            layer: line.layer,
            parentLineId: line.parentLineId,
            estWidth: line.width,
            estHeight: line.height,
            directAreaSqft: line.directAreaSqft,
            quantity: line.priced!.quantity,
            categoryLockId: line.basis.lockId,
            measurementSource: line.sourceUnitTypeId == null
                ? 'manual'
                : 'project_library',
            sourceProjectId: line.sourceProjectId,
            sourceUnitTypeId: line.sourceUnitTypeId,
            sourceVersion: line.sourceVersion,
            appliedRuleId: line.priced!.rule.id,
            appliedBandLabel: line.priced!.rule.bandLabels?.call('en'),
            // The version that actually produced this number. Checked above to
            // equal the one the line's lock holds, so it cannot record a
            // version that did not price it.
            appliedRateCardVersion: pinnedRateCardVersion,
            appliedDiscountPct: line.basis.discountPct,
            standardRateSen: line.priced!.standardRateSen,
            rateSen: line.priced!.rateSen,
            billedQty: line.priced!.billedQty.toString(),
            billedUnit: line.priced!.billedUnit,
            lineTotal: line.priced!.total,
            materialDeferred: line.priced!.materialDeferred,
          ),
      ],
    ),
  );
}

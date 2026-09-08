/// Site measurement and final pricing, on the handset. SPEC.md §11 Phase 6.
///
/// The rule lives in `pricing/final_pricing.dart`, which is pure and shared
/// with the server through `shared/pricing-fixtures.json`. This file only
/// stores what that returns, so there is no second place where "a line reprices
/// at the card it recorded" could quietly stop being true.
///
/// **Three things are written together or not at all**: the tape on the line,
/// the repriced figures beside the estimate, and the order's own total. A final
/// total with no billed quantity behind it is a number nobody can explain a
/// year later; a measured line with no total is a window that silently drops
/// out of a balance somebody then collects.
///
/// **Nothing here writes over the estimate.** §6.3 keeps both, so the variance
/// report has something to compare and a customer asking why the bill differs
/// from the quote can be shown the two side by side.
///
/// **Offline is the default** (§11 Phase 6: *works fully offline in a house
/// with no signal*). Every card this needs was pulled before the visit and is
/// read from local storage; nothing here touches the network, and the push goes
/// through the same outbox as everything else.
library;

import 'package:drift/drift.dart';

import '../core/length.dart';
import '../core/money.dart';
import '../pricing/final_pricing.dart';
import '../pricing/models.dart';
import 'database.dart';
import 'quote_repository.dart' show newId;

/// Why a measurement could not be recorded.
enum MeasurementRefusal {
  /// The order is closed or cancelled. Measuring one would produce a bill for
  /// a job that is not happening.
  orderIsTerminal('order_is_terminal'),

  /// A dimension of zero or less. A tape does not read that, so it is a
  /// mistyped entry, and a zero-width line prices at zero.
  notAMeasurement('not_a_measurement'),

  /// No such line on this order.
  noSuchLine('no_such_line'),

  /// This line's rule needs a height and none was given.
  ///
  /// Bug hunt, 2026-09-08 (FINDINGS.md #6). `MeasureSheet` already gates on
  /// this correctly, so today nothing reaches here — but the repository must
  /// not trust its one caller to keep doing so forever. A future second entry
  /// point (a bulk-measure tool, a different screen) that skipped that gate
  /// would otherwise mark a line `isSiteMeasured: true` with no real height,
  /// and `price_line` would only catch it downstream, after the write.
  missingHeight('missing_height');

  const MeasurementRefusal(this.wire);

  final String wire;
}

/// What recording a measurement did.
class MeasurementOutcome {
  const MeasurementOutcome({this.refusal, this.pricing});

  /// Null when it was recorded.
  final MeasurementRefusal? refusal;

  /// The order as it now stands, priced as far as it can be. Null when the
  /// measurement was refused.
  final FinalPricing? pricing;

  bool get isRecorded => refusal == null;
}

class MeasurementRepository {
  MeasurementRepository(this._db);

  final AppDatabase _db;

  /// Records the tape on one line and reprices the whole order. §11 Phase 6.
  ///
  /// [cards] holds every published card version the handset has pulled, keyed
  /// by version. A line whose version is missing refuses inside
  /// `repriceOrder` — it is never priced at another, because falling back to
  /// today's card is exactly what the deposit was taken to prevent.
  ///
  /// The whole order reprices on every measurement rather than just the line
  /// that moved. It is a handful of lines and pure arithmetic, and it means the
  /// stored totals cannot drift out of step with the lines under them.
  Future<MeasurementOutcome> recordMeasurement({
    required String orderId,
    required String lineId,
    required Length width,
    Length? height,
    required Map<int, RateCard> cards,
    required DateTime at,
    String? byUserId,
    String? materialKey,
  }) => _db.transaction(() async {
    final order = await (_db.select(
      _db.orders,
    )..where((o) => o.id.equals(orderId))).getSingleOrNull();

    if (order == null || _isTerminal(order.status)) {
      return const MeasurementOutcome(
        refusal: MeasurementRefusal.orderIsTerminal,
      );
    }

    // Zero is not a measurement. A tape does not read it, and a zero-width
    // line prices at zero — which is a discount nobody authorised arriving
    // through a typo.
    if (width.tmm <= 0 || (height != null && height.tmm <= 0)) {
      return const MeasurementOutcome(
        refusal: MeasurementRefusal.notAMeasurement,
      );
    }

    final line =
        await (_db.select(_db.orderLines)
              ..where((l) => l.id.equals(lineId) & l.orderId.equals(orderId)))
            .getSingleOrNull();

    if (line == null) {
      return const MeasurementOutcome(refusal: MeasurementRefusal.noSuchLine);
    }

    // Defense in depth, not the primary gate: `MeasureSheet` already derives
    // whether this line needs a height from the same rule and disables Save
    // until it has one. This exists so a future second caller that skipped
    // that gate cannot mark a line "measured" with no real height behind it.
    final rule = cards[line.appliedRateCardVersion]?.rules
        .where((r) => r.id == line.appliedRuleId)
        .firstOrNull;
    final needsHeight =
        rule != null &&
        height == null &&
        (rule.bandField == BandField.height ||
            rule.basis == PriceBasis.perSqft ||
            rule.basis == PriceBasis.perRoll);
    if (needsHeight) {
      return const MeasurementOutcome(
        refusal: MeasurementRefusal.missingHeight,
      );
    }

    await (_db.update(_db.orderLines)..where((l) => l.id.equals(lineId))).write(
      OrderLinesCompanion(
        finalWidthTmm: Value(width.tmm),
        finalHeightTmm: Value(height?.tmm),
        isSiteMeasured: const Value(true),
        measuredByUserId: Value(byUserId),
        measuredAt: Value(at),
        // A material chosen on site. Passed only when the measurer picked one,
        // so a null here never clears a choice already made.
        materialKey: materialKey == null
            ? const Value.absent()
            : Value(materialKey),
      ),
    );

    return MeasurementOutcome(pricing: await _repriceAndStore(orderId, cards));
  });

  /// Reprices an order without recording anything new.
  ///
  /// What the measurer reads before they leave the house (§11 Phase 6:
  /// *variance visible to the measurer before they leave*), and what the order
  /// screen shows on the way in.
  Future<FinalPricing> priceOrder({
    required String orderId,
    required Map<int, RateCard> cards,
  }) async => repriceOrder(lines: await _measuredLines(orderId), cards: cards);

  Future<FinalPricing> _repriceAndStore(
    String orderId,
    Map<int, RateCard> cards,
  ) async {
    final pricing = repriceOrder(
      lines: await _measuredLines(orderId),
      cards: cards,
    );

    for (final priced in pricing.lines) {
      final result = priced.priced;
      // A refused line is left exactly as it was. Writing a partial row —
      // a rate with no total, a total with no quantity — would leave the
      // handset holding a figure nothing produced.
      if (result == null) continue;

      await (_db.update(
        _db.orderLines,
      )..where((l) => l.id.equals(priced.id))).write(
        OrderLinesCompanion(
          finalBilledQty: Value(result.billedQty.toString()),
          finalBilledUnit: Value(result.billedUnit),
          finalRuleId: Value(result.rule.id),
          // Stored in English: this column is read by the dashboard and the
          // variance report, not printed for a customer. What a customer sees
          // is localised at the moment it is shown, from the card.
          finalBandLabel: Value(result.rule.bandLabels?.call('en')),
          finalRateSen: Value(result.rateSen),
          finalLineTotalSen: Value(result.total.sen),
        ),
      );
    }

    final total = pricing.finalTotal;

    // Read here rather than carried in, so the balance is worked out from the
    // deposit as it stands in this transaction. A cached figure primed by a
    // separate call would give a wrong balance the moment somebody forgot to
    // prime it, and it would give it silently.
    final order = await (_db.select(
      _db.orders,
    )..where((o) => o.id.equals(orderId))).getSingle();

    await (_db.update(_db.orders)..where((o) => o.id.equals(orderId))).write(
      OrdersCompanion(
        // Null until every line has priced. A total that quietly excluded a
        // line would be a balance somebody collects and a window nobody bills
        // for — so an order half measured reports no total at all.
        finalTotalSen: Value(total?.sen),
        hasUnmeasuredLines: Value(!pricing.isComplete),
        // The balance follows the total, and is zero while there is no total:
        // a balance worked out from an estimate is a number the customer
        // remembers and the tape then contradicts.
        //
        // Never negative. A final under the deposit already taken is §13 B4,
        // unanswered, and a negative balance on a screen would be this file
        // answering it.
        balanceDueSen: Value(
          total == null ? 0 : _atLeastZero(total.sen - order.depositPaidSen),
        ),
      ),
    );

    return pricing;
  }

  static int _atLeastZero(int sen) => sen < 0 ? 0 : sen;

  /// What still stands between this order and a bill, and why for each.
  ///
  /// The list a measurer works down before leaving the house. Deliberately not
  /// a count: "three lines outstanding" sends somebody hunting, and the
  /// refusal on each says whether it wants a tape, a material, or a card the
  /// handset has not pulled.
  ///
  /// It does **not** decide whether the order may move to `measured`. That is
  /// `advanceOrder`'s guard, and a second answer here would eventually
  /// disagree with it.
  Future<List<FinalLine>> outstandingOf({
    required String orderId,
    required Map<int, RateCard> cards,
  }) async => (await priceOrder(orderId: orderId, cards: cards)).outstanding;

  Future<List<MeasuredLine>> _measuredLines(String orderId) async {
    final rows =
        await (_db.select(_db.orderLines)
              ..where((l) => l.orderId.equals(orderId))
              ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
            .get();

    return [
      for (final row in rows)
        MeasuredLine(
          id: row.id,
          variant: row.variant,
          materialKey: row.materialKey,
          layer: Layer.fromWire(row.layer),
          quantity: row.quantity,
          estimateTotal: Money.sen(row.lineTotalSen),
          appliedRateCardVersion: row.appliedRateCardVersion,
          finalWidth: row.finalWidthTmm == null
              ? null
              : Length.tenths(row.finalWidthTmm!),
          finalHeight: row.finalHeightTmm == null
              ? null
              : Length.tenths(row.finalHeightTmm!),
          materialDeferred: row.materialDeferred,
        ),
    ];
  }

  bool _isTerminal(String status) =>
      status == 'closed' || status == 'cancelled';

  /// Writes an `order_events` row saying the tape was taken. §6.3, append only.
  ///
  /// Separate from the measurement itself because the history is what somebody
  /// reads a year later: one row per visit, not one per window.
  Future<void> recordVisit({
    required String orderId,
    required DateTime at,
    String? byUserId,
    String? note,
  }) => _db
      .into(_db.orderEvents)
      .insert(
        OrderEventsCompanion.insert(
          id: newId(),
          orderId: orderId,
          event: 'measured_on_site',
          note: Value(note?.trim().isNotEmpty == true ? note!.trim() : null),
          byUserId: Value(byUserId),
          at: at,
        ),
      );
}

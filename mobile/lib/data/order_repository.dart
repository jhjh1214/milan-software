/// Reading and writing confirmed orders. SPEC.md §6.3.
///
/// The rule for whether a quote may become an order lives in
/// `pricing/conversion.dart`. This file only stores what that returns, so there
/// is no second place where "a deposit confirms an order" could quietly stop
/// being true.
library;

import 'package:drift/drift.dart';

import '../core/money.dart';
import '../pricing/conversion.dart';
import '../pricing/einvoice_threshold.dart';
import '../pricing/order_status.dart';
import '../pricing/price_override.dart';
import 'database.dart';
import 'quote_repository.dart' show newId;

class OrderRepository {
  final AppDatabase _db;

  OrderRepository(this._db);

  /// Writes a confirmed order, its lines and its first event, in **one**
  /// transaction.
  ///
  /// All or nothing. An order without its lines is a total with nothing behind
  /// it; lines without an order are rows nobody will ever find. And an order
  /// with no `confirmed` event has no history from the moment it mattered most.
  Future<void> store(OrderDraft draft, {String? byUserId}) =>
      _db.transaction(() async {
        await _db
            .into(_db.orders)
            .insert(
              OrdersCompanion.insert(
                id: draft.id,
                quoteId: draft.quoteId,
                channel: draft.channel.wire,
                pinnedRateCardVersion: draft.pinnedRateCardVersion,
                customerName: Value(draft.customerName),
                customerPhone: Value(draft.customerPhone),
                deliveryZoneId: Value(draft.deliveryZoneId),
                deliveryChargeSen: Value(draft.deliveryCharge.sen),
                siteAddress: Value(draft.siteAddress),
                sitePostcode: Value(draft.sitePostcode),
                siteReadyFrom: Value(draft.siteReadyFrom),
                // Stamped only when something was captured, so a later
                // capture is never refused against an empty record.
                siteCapturedAt: Value(
                  draft.siteAddress != null ||
                          draft.sitePostcode != null ||
                          draft.siteReadyFrom != null
                      ? draft.confirmedAt
                      : null,
                ),
                estimateTotalSen: draft.estimateTotal.sen,
                depositPaidSen: Value(draft.depositPaid.sen),
                // Left at zero until final pricing. A balance worked out from
                // an estimate is a number the customer remembers and the tape
                // contradicts, and §8.5 promises the final can only fall.
                hasUnmeasuredLines: Value(draft.hasUnmeasuredLines),
                confirmedByUserId: Value(byUserId),
                confirmedAt: draft.confirmedAt,
              ),
            );

        for (final line in draft.lines) {
          await _db
              .into(_db.orderLines)
              .insert(
                OrderLinesCompanion.insert(
                  id: line.id,
                  orderId: draft.id,
                  quoteLineId: line.quoteLineId,
                  sortOrder: line.sortOrder,
                  room: line.room,
                  variant: line.variant,
                  materialKey: Value(line.materialKey),
                  layer: line.layer,
                  parentLineId: Value(line.parentLineId),
                  estWidthTmm: Value(line.estWidth?.tmm),
                  estHeightTmm: Value(line.estHeight?.tmm),
                  directAreaSqft: Value(line.directAreaSqft?.toString()),
                  quantity: Value(line.quantity),
                  categoryLockId: Value(line.categoryLockId),
                  appliedRuleId: line.appliedRuleId,
                  appliedBandLabel: Value(line.appliedBandLabel),
                  appliedRateCardVersion: line.appliedRateCardVersion,
                  appliedDiscountPct: Value(line.appliedDiscountPct.toString()),
                  standardRateSen: line.standardRateSen,
                  rateSen: line.rateSen,
                  billedQty: line.billedQty,
                  billedUnit: line.billedUnit,
                  lineTotalSen: line.lineTotal.sen,
                  materialDeferred: Value(line.materialDeferred),
                  measurementSource: Value(line.measurementSource),
                  sourceProjectId: Value(line.sourceProjectId),
                  sourceUnitTypeId: Value(line.sourceUnitTypeId),
                  sourceVersion: Value(line.sourceVersion),
                ),
              );
        }

        await _db
            .into(_db.orderEvents)
            .insert(
              OrderEventsCompanion.insert(
                id: newId(),
                orderId: draft.id,
                event: 'confirmed',
                note: Value(
                  'Deposit ${draft.depositPaid.format()} of '
                  '${draft.estimateTotal.format()}',
                ),
                byUserId: Value(byUserId),
                at: draft.confirmedAt,
              ),
            );
      });

  /// The order confirmed from [quoteId], if there is one.
  ///
  /// One quote confirms once. A second deposit on the same quote adds money to
  /// the order that already exists rather than creating another.
  Future<OrderRow?> forQuote(String quoteId) => (_db.select(
    _db.orders,
  )..where((o) => o.quoteId.equals(quoteId))).getSingleOrNull();

  Future<List<OrderLineRow>> linesOf(String orderId) =>
      (_db.select(_db.orderLines)
            ..where((l) => l.orderId.equals(orderId))
            ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
          .get();

  Future<List<OrderEventRow>> historyOf(String orderId) =>
      (_db.select(_db.orderEvents)
            ..where((e) => e.orderId.equals(orderId))
            ..orderBy([(e) => OrderingTerm.asc(e.at)]))
          .get();

  /// Adds a later payment to an order that already exists.
  ///
  /// Only the money taken moves. The estimate never does — it is the record of
  /// what was quoted — and `balance_due_sen` stays untouched until final
  /// pricing, because there is no honest balance to state before the tape has
  /// been out.
  Future<void> recordFurtherPayment({
    required String orderId,
    required Money amount,
    required DateTime at,
    String? byUserId,
  }) => _db.transaction(() async {
    final order = await (_db.select(
      _db.orders,
    )..where((o) => o.id.equals(orderId))).getSingle();

    await (_db.update(_db.orders)..where((o) => o.id.equals(orderId))).write(
      OrdersCompanion(depositPaidSen: Value(order.depositPaidSen + amount.sen)),
    );

    await _db
        .into(_db.orderEvents)
        .insert(
          OrderEventsCompanion.insert(
            id: newId(),
            orderId: orderId,
            event: 'payment_taken',
            note: Value(amount.format()),
            byUserId: Value(byUserId),
            at: at,
          ),
        );
  });

  /// Moves an order along the pipeline, or says why it cannot. SPEC.md §6.3.
  ///
  /// The decision belongs to `pricing/order_status.dart` and is taken there,
  /// against the line state this reads out of the database. Nothing about which
  /// transitions are legal lives in this file, and nothing about SQLite lives
  /// in that one.
  ///
  /// The status write and its `order_events` row go in **one** transaction. A
  /// status that moved with no event behind it is a job whose history has a
  /// hole exactly where somebody will later look.
  Future<StatusChange> advanceStatus({
    required String orderId,
    required OrderStatus to,
    required DateTime at,
    required ThresholdConfig thresholds,
    String? byUserId,
    String? reason,
  }) => _db.transaction(() async {
    final order = await (_db.select(
      _db.orders,
    )..where((o) => o.id.equals(orderId))).getSingle();

    final lines = await linesOf(orderId);

    final decision = advanceOrder(
      from: OrderStatus.fromWire(order.status),
      to: to,
      reason: reason,
      // §10.4, enforced here rather than in a screen. Checked against the
      // FINAL total where one exists and the estimate otherwise: an order not
      // yet measured has not crossed anything, and using the estimate as if it
      // had would hold jobs the tape will bring back under the line.
      //
      // The thresholds come from the caller because they live on the rate
      // card (§10.3), and this file has no business reading one.
      //
      // The stage cannot change what this call decides *here*, because the
      // only stage-sensitive branch is the RM8,000 fair prompt and that one
      // asks without blocking — so `blocksAdvance` is stage-independent
      // today. It is passed correctly anyway: `mustCapture` is what a screen
      // reads, and a caller that hard-coded the stage would be wrong the
      // moment the two thresholds meet.
      threshold: checkThreshold(
        total: Money.sen(order.finalTotalSen ?? order.estimateTotalSen),
        stage: order.finalTotalSen == null
            ? ThresholdStage.estimate
            : ThresholdStage.finalPricing,
        config: thresholds,
        buyerDetailsComplete: buyerDetailsComplete(buyerDetailsOf(order)),
        einvoiceRequested: order.einvoiceRequested,
      ),
      lines: [
        for (final l in lines)
          OrderLineState(
            // The same rule as `OrderLineDraft.needsMeasuring`, and it is the
            // only rule: everything needs a tape taking to it. §8.5 promises
            // the final will be the same or lower, and that promise is kept by
            // measuring. Phase 6 is where per-line exceptions would earn a
            // home; inventing one here would put a second, quieter answer
            // beside the first.
            needsMeasuring: true,
            hasFinalDimensions: l.isSiteMeasured,
            materialDeferred: l.materialDeferred,
            materialChosen: l.materialKey != null,
          ),
      ],
    );

    if (!decision.isAllowed) return decision;

    await (_db.update(_db.orders)..where((o) => o.id.equals(orderId))).write(
      OrdersCompanion(status: Value(decision.to!.wire)),
    );

    await _db
        .into(_db.orderEvents)
        .insert(
          OrderEventsCompanion.insert(
            id: newId(),
            orderId: orderId,
            event: decision.to!.wire,
            // The cancellation reason is the row §13 B3 will be settled from,
            // so it is stored as given rather than summarised.
            note: Value(
              reason?.trim().isNotEmpty == true ? reason!.trim() : null,
            ),
            byUserId: Value(byUserId),
            at: at,
          ),
        );

    return decision;
  });

  /// Moves a line's total by hand, and writes the row that justifies it.
  /// SPEC.md §6.5.
  ///
  /// The rule is in `pricing/price_override.dart`. This stores what it returns:
  /// the new total, the `is_overridden` marker the screen and the printed quote
  /// read, the append-only `price_overrides` row, and an `order_events` entry —
  /// **in one transaction, or none of it.**
  ///
  /// An override that applied without its audit row would be the one case the
  /// weekly review cannot show, which is precisely the case somebody would want
  /// hidden. §6.5 puts the entire control on that review, so the row is not a
  /// side effect of the price change; it is the reason the price change is
  /// allowed at all.
  Future<OverrideDecision> overrideLineTotal({
    required String orderLineId,
    required Money newTotal,
    required String? reason,
    required String? adminUserId,
    required bool isAdmin,
    required DateTime at,
    String? deviceId,
  }) => _db.transaction(() async {
    final line = await (_db.select(
      _db.orderLines,
    )..where((l) => l.id.equals(orderLineId))).getSingle();

    final order = await (_db.select(
      _db.orders,
    )..where((o) => o.id.equals(line.orderId))).getSingle();

    final decision = overrideLinePrice(
      before: Money.sen(line.lineTotalSen),
      after: newTotal,
      reason: reason,
      adminUserId: adminUserId,
      isAdmin: isAdmin,
      orderIsTerminal: OrderStatus.fromWire(order.status).isTerminal,
    );

    if (!decision.isApplied) return decision;
    final record = decision.record!;

    await (_db.update(
      _db.orderLines,
    )..where((l) => l.id.equals(orderLineId))).write(
      OrderLinesCompanion(
        lineTotalSen: Value(record.after.sen),
        // The marker the screen and the printed quote read. Never cleared:
        // a line that was overridden once stays a line somebody moved by
        // hand, whatever it is moved to afterwards.
        isOverridden: const Value(true),
      ),
    );

    await _db
        .into(_db.priceOverrides)
        .insert(
          PriceOverridesCompanion.insert(
            id: newId(),
            orderLineId: orderLineId,
            orderId: line.orderId,
            beforeSen: record.before.sen,
            afterSen: record.after.sen,
            reason: record.reason,
            adminUserId: record.adminUserId,
            deviceId: Value(deviceId),
            at: at,
          ),
        );

    await _db
        .into(_db.orderEvents)
        .insert(
          OrderEventsCompanion.insert(
            id: newId(),
            orderId: line.orderId,
            event: 'price_overridden',
            note: Value(
              '${record.before.format()} → ${record.after.format()}: '
              '${record.reason}',
            ),
            byUserId: Value(record.adminUserId),
            at: at,
          ),
        );

    return decision;
  });

  /// Every override in a window, newest first. SPEC.md §6.5 and §11 Phase 5.
  ///
  /// *"build the 'overrides this week' screen — without it the log is never read
  /// and the control does not exist."* The query is here so the screen is cheap
  /// to build; a control nobody can see is not a control.
  ///
  /// [from] is inclusive and [to] exclusive, so a week is seven days with no
  /// midnight straddling either edge.
  Future<List<PriceOverrideRow>> overridesBetween({
    required DateTime from,
    required DateTime to,
  }) =>
      (_db.select(_db.priceOverrides)
            ..where(
              (o) =>
                  o.at.isBiggerOrEqualValue(from) & o.at.isSmallerThanValue(to),
            )
            ..orderBy([(o) => OrderingTerm.desc(o.at)]))
          .get();

  /// Every override on one order, oldest first — the line's own history.
  Future<List<PriceOverrideRow>> overridesOn(String orderId) =>
      (_db.select(_db.priceOverrides)
            ..where((o) => o.orderId.equals(orderId))
            ..orderBy([(o) => OrderingTerm.asc(o.at)]))
          .get();

  /// Writes back the order number the server issued.
  ///
  /// Like a receipt number, it is not invented here: two part-timers offline at
  /// one fair would produce the same one, on a document the customer takes
  /// away.
  Future<void> settleOrderNo({
    required String orderId,
    required String orderNo,
    required DateTime at,
  }) => (_db.update(_db.orders)..where((o) => o.id.equals(orderId))).write(
    OrdersCompanion(orderNo: Value(orderNo), syncedAt: Value(at)),
  );

  /// Orders still waiting for their number, shown as "pending sync".
  Future<List<OrderRow>> awaitingOrderNo() =>
      (_db.select(_db.orders)..where((o) => o.orderNo.isNull())).get();

  /// Reads the buyer details off an order row. §10.3.
  ///
  /// A function rather than a stored flag: what counts as complete is a rule
  /// (`pricing/einvoice_threshold.dart`), and a boolean column beside it would
  /// be a second answer that drifts the first time somebody edits a field
  /// without recomputing it.
  static BuyerDetails buyerDetailsOf(OrderRow order) => BuyerDetails(
    name: order.customerName,
    tin: order.buyerTin,
    idType: order.buyerIdType,
    idNumber: order.buyerIdNumber,
    addressLine1: order.buyerAddressLine1,
    addressLine2: order.buyerAddressLine2,
    city: order.buyerCity,
    state: order.buyerState,
    postcode: order.buyerPostcode,
  );

  /// Records what was captured about the buyer. §10.3.
  ///
  /// Every field is optional and passing null leaves what is there: a screen
  /// that saves one section must not blank another. Trimmed on the way in, so
  /// a tabbed-through field is stored as absent rather than as a space that
  /// satisfies a legal requirement it does not meet.
  ///
  /// The customer's name lives on the order already and is updated here too,
  /// because an e-invoice needs the buyer's legal name and a fair may have
  /// recorded "Ah Lian's mother".
  /// Where the visit is, captured after confirmation — the customer did not
  /// have the address at the fair and sends it later. §13 C10.
  ///
  /// Replaces all three fields and stamps [at], which goes up with the push so
  /// the server can refuse it if the office has typed something newer since.
  Future<void> recordSiteDetails({
    required String orderId,
    required String? address,
    required String? postcode,
    required DateTime? readyFrom,
    required DateTime at,
  }) => (_db.update(_db.orders)..where((o) => o.id.equals(orderId))).write(
    OrdersCompanion(
      siteAddress: Value(address),
      sitePostcode: Value(postcode),
      siteReadyFrom: Value(readyFrom),
      siteCapturedAt: Value(at),
    ),
  );

  Future<void> recordBuyerDetails({
    required String orderId,
    String? name,
    String? tin,
    String? idType,
    String? idNumber,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? state,
    String? postcode,
    String? msicCode,
    bool? einvoiceRequested,
  }) async {
    Value<String?> keep(String? v) =>
        v == null ? const Value.absent() : Value(_trimmedOrNull(v));

    await (_db.update(_db.orders)..where((o) => o.id.equals(orderId))).write(
      OrdersCompanion(
        customerName: keep(name),
        buyerTin: keep(tin),
        buyerIdType: keep(idType),
        buyerIdNumber: keep(idNumber),
        buyerAddressLine1: keep(addressLine1),
        buyerAddressLine2: keep(addressLine2),
        buyerCity: keep(city),
        buyerState: keep(state),
        buyerPostcode: keep(postcode),
        buyerMsicCode: keep(msicCode),
        einvoiceRequested: einvoiceRequested == null
            ? const Value.absent()
            : Value(einvoiceRequested),
      ),
    );
  }

  static String? _trimmedOrNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

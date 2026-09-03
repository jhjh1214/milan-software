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
import '../pricing/order_status.dart';
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
                  estWidthTmm: line.estWidth.tmm,
                  estHeightTmm: Value(line.estHeight?.tmm),
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
}

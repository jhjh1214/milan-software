/// Recording money taken. SPEC.md §6.4.
///
/// **Records, never processes.** The card terminal is somebody else's problem;
/// a row here is a note that money changed hands.
///
/// Append only. A refund is a new row with `kind: refund`, and nothing already
/// written is edited — the cash-up reconciles what happened, not what the
/// drawer looks like now.
library;

import 'package:drift/drift.dart';

import '../core/money.dart';
import '../pricing/cash_up.dart';
import 'database.dart';

class PaymentRepository {
  final AppDatabase _db;

  PaymentRepository(this._db);

  /// Writes down a payment. Offline, immediately, with no server round trip.
  ///
  /// [receiptNo] is deliberately absent: the server issues it, it goes on a
  /// legal document, and two handsets offline at one fair would invent the
  /// same number. Until sync the app shows "pending sync".
  Future<String> record({
    required String id,
    required String quoteId,
    required PaymentKind kind,
    required PaymentMethod method,
    required int amountSen,
    required DateTime takenAt,
    String? categoryLockId,
    String? externalRef,
    String? takenByUserId,
    String? deviceId,
  }) async {
    await _db
        .into(_db.payments)
        .insert(
          PaymentsCompanion.insert(
            id: id,
            quoteId: quoteId,
            categoryLockId: Value(categoryLockId),
            kind: kind.wire,
            method: method.wire,
            amountSen: amountSen,
            externalRef: Value(externalRef),
            takenByUserId: Value(takenByUserId),
            takenAt: takenAt,
            deviceId: Value(deviceId),
          ),
        );
    return id;
  }

  /// The body the server expects. Field names match its schema exactly, so
  /// there is no translation layer to get wrong.
  ///
  /// No `receipt_no`: the device does not have one and must not invent one.
  Map<String, dynamic> pushBodyFor(PaymentRow row) => {
    'id': row.id,
    'quote_id': row.quoteId,
    'category_lock_id': row.categoryLockId,
    'kind': row.kind,
    'amount_sen': row.amountSen,
    'method': row.method,
    'external_ref': row.externalRef,
    // UTC on the wire. The receipt number's period comes from this, so a
    // payment taken at 11pm must not become the next month in transit.
    'taken_at': row.takenAt.toUtc().toIso8601String(),
    'device_id': row.deviceId,
  };

  /// Payments still waiting for a receipt number.
  ///
  /// Shown as "pending sync" rather than blank: a salesperson who can see the
  /// number is coming does not go looking for one that was never issued.
  Future<List<PaymentRow>> awaitingReceipt() =>
      (_db.select(_db.payments)..where((p) => p.receiptNo.isNull())).get();

  Future<List<PaymentRow>> forQuote(String quoteId) =>
      (_db.select(_db.payments)
            ..where((p) => p.quoteId.equals(quoteId))
            ..orderBy([(p) => OrderingTerm.asc(p.takenAt)]))
          .get();

  /// Everything taken on one calendar day, optionally by one person.
  ///
  /// The day is a local day, not a UTC one: a cash-up is about what somebody
  /// is holding when they stop work, and 8am Malaysian time is the previous
  /// day in UTC.
  Future<List<PaymentRow>> takenOn(DateTime day, {String? byUserId}) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    final query = _db.select(_db.payments)
      ..where((p) => p.takenAt.isBiggerOrEqualValue(start))
      ..where((p) => p.takenAt.isSmallerThanValue(end))
      ..orderBy([(p) => OrderingTerm.asc(p.takenAt)]);
    if (byUserId != null) {
      query.where((p) => p.takenByUserId.equals(byUserId));
    }
    return query.get();
  }

  /// One person's day, totalled by method and checked against what they hold.
  Future<CashUp> cashUp(
    DateTime day, {
    String? byUserId,
    Map<PaymentMethod, Money> counted = const {},
  }) async {
    final rows = await takenOn(day, byUserId: byUserId);
    return cashUpFor([
      for (final row in rows)
        CashUpEntry(
          kind: PaymentKind.fromWire(row.kind),
          method: PaymentMethod.fromWire(row.method),
          amountSen: row.amountSen,
        ),
    ], counted: counted);
  }

  /// Ties a deposit to the hold it bought, once the hold exists.
  ///
  /// Two writes rather than one because the payment is recorded first: if the
  /// app dies between them the money is still on the record, which is the half
  /// that matters. A lock with no payment is a bug to find; a payment with no
  /// lock is a customer to call back.
  Future<void> linkToLock({
    required String paymentId,
    required String lockId,
  }) async {
    await (_db.update(_db.payments)..where((p) => p.id.equals(paymentId)))
        .write(PaymentsCompanion(categoryLockId: Value(lockId)));
    await (_db.update(_db.categoryLocks)..where((l) => l.id.equals(lockId)))
        .write(CategoryLocksCompanion(depositPaymentId: Value(paymentId)));
  }
}

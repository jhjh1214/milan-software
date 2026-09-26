/// The push side. Â§9.2.
///
/// A finished quote is written to the outbox and forgotten about. It goes up
/// when there is signal, which at a fair might be that evening in the car. No
/// screen ever waits on this.
///
/// Three properties matter, and each one is a specific failure avoided:
///
/// - **Idempotent.** The row carries the quote's own client-generated id, and
///   the server is idempotent on it. A connection that drops after the server
///   committed but before the response arrived is the normal case, not an edge
///   case, and the device has no way to tell it apart from a failure.
/// - **FIFO.** Rows drain oldest first. A queue that reorders is one nobody can
///   reason about when it goes wrong.
/// - **Nothing is deleted except on confirmation.** A row that has failed too
///   many times is *parked*, not dropped. It is somebody's order.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../data/database.dart';
import '../data/quote_repository.dart' show newId;
import 'api_client.dart';

/// How many failures before a row stops being retried.
///
/// Not zero and not infinite. A row that has failed this many times is not
/// going to succeed by being tried again, and leaving it at the head of a FIFO
/// queue would stop every quote behind it from ever reaching the office.
const int kMaxAttempts = 8;

/// What one drain did.
class DrainReport {
  /// Quote ids the server confirmed. Includes duplicates: a retry the server
  /// had already seen is a success.
  final List<String> sent;

  /// Rows that stopped being retried this run.
  final List<String> parked;

  /// Quotes where the server priced a line differently. The order was still
  /// accepted (Â§9.4) â€” this is a review task, not a failure.
  final List<String> disagreed;

  /// Why the drain stopped early, if it did.
  final SyncFailure? failure;

  const DrainReport({
    this.sent = const [],
    this.parked = const [],
    this.disagreed = const [],
    this.failure,
  });

  bool get ok => failure == null;
}

class Outboxer {
  final AppDatabase db;
  final ApiClient api;
  final DateTime Function() clock;

  Outboxer({required this.db, required this.api, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  /// Queues a quote to be sent.
  ///
  /// The body is serialised **now** and frozen. What goes up is what the
  /// customer was shown, not what the quote has since been edited into.
  ///
  /// Enqueuing the same quote twice replaces the earlier row rather than adding
  /// a second: the outbox holds work to do, not a history of intentions, and
  /// two rows for one quote would mean two pushes where the second tells the
  /// server nothing new.
  Future<void> enqueueQuote(String quoteId, Map<String, dynamic> payload) =>
      _enqueue('quote', quoteId, payload);

  /// Queues a payment to be sent. Â§6.4.
  ///
  /// Its receipt number comes back on the way out, and is written onto the
  /// payment. Until then the app shows "pending sync" rather than a number it
  /// made up â€” the number goes on paper a customer keeps, and two handsets
  /// offline at one fair would invent the same one.
  Future<void> enqueuePayment(String paymentId, Map<String, dynamic> payload) =>
      _enqueue('payment', paymentId, payload);

  /// Queues a confirmed order to be sent. Â§6.3.
  ///
  /// Its number comes back on the way out, the same way a receipt number does
  /// and for the same reason. A deposit already changed hands before this row
  /// existed, so nothing about the sale waits on it â€” only the number does.
  Future<void> enqueueOrder(String orderId, Map<String, dynamic> payload) =>
      _enqueue('order', orderId, payload);

  /// Queues one step along the pipeline. Â§6.3.
  ///
  /// Keyed on the **event id**, not the order. An order walks the pipeline
  /// many times and each move is its own row: keying on the order would have
  /// the second step overwrite the first while it was still queued, and the
  /// history would lose a step that really happened.
  Future<void> enqueueStatusChange(
    String eventId,
    Map<String, dynamic> payload,
  ) => _enqueue('order_status', eventId, payload);

  /// Queues what was captured about the buyer. Â§10.3.
  ///
  /// Keyed on the **order id**, unlike a status change. Each capture carries
  /// this handset's whole view of the buyer, so a later one supersedes an
  /// earlier one still waiting in the queue and only the newest needs to go up
  /// â€” there is no history here to lose, only a record to correct.
  ///
  /// It has to go up at all because the **office** runs the export. Details
  /// that never leave the handset are the same as no details as far as the
  /// accounts system is concerned, which is the failure a rate lock had before
  /// it was pushed.
  Future<void> enqueueBuyerDetails(
    String orderId,
    Map<String, dynamic> payload,
  ) => _enqueue('buyer_details', orderId, payload);

  /// Queues where a visit is, captured after the order went up. §13 C10.
  ///
  /// Keyed on the order id: each capture carries the whole record, so a later
  /// one supersedes an earlier one still waiting and only the newest goes up.
  Future<void> enqueueSiteDetails(
    String orderId,
    Map<String, dynamic> payload,
  ) => _enqueue('site_details', orderId, payload);

  /// Queues one site measurement to go up. §11 Phase 6.
  ///
  /// Keyed on the **line id**, not the order — a measurement is naturally per
  /// line. Several lines on one order can each be queued independently, and
  /// each is its own record rather than one that supersedes another the way
  /// a buyer capture does.
  Future<void> enqueueMeasurement(
    String lineId,
    Map<String, dynamic> payload,
  ) => _enqueue('measurement', lineId, payload);

  /// Queues a hold to go up. Â§6.1.
  ///
  /// A hold that never leaves the handset that took the deposit is a hold the
  /// customer paid RM300 for and cannot use anywhere else.
  Future<void> enqueueLock(String lockId, Map<String, dynamic> payload) =>
      _enqueue('lock', lockId, payload);

  /// Queues one answer to the category prompt. Â§6.2.
  ///
  /// A decline has to reach the server as reliably as a sale, or the report
  /// that says what fairs are leaving on the table is quietly wrong in the
  /// flattering direction.
  Future<void> enqueueDepositPrompt(
    String promptId,
    Map<String, dynamic> payload,
  ) => _enqueue('deposit_prompt', promptId, payload);

  /// Queues a part-timer's own floor-plan submission. SPEC.md Phase 8.
  ///
  /// Keyed on the **device-generated unit type id** -- the same id the
  /// server will use for the row it creates, so a retry after a dropped
  /// fair-tent connection is idempotent the same way an order push is.
  Future<void> enqueueLibrarySubmission(
    String unitTypeId,
    Map<String, dynamic> payload,
  ) => _enqueue('library_submission', unitTypeId, payload);

  Future<void> _enqueue(
    String entityType,
    String entityId,
    Map<String, dynamic> payload,
  ) async {
    // Matched on the KIND as well as the id. Two different kinds of work can
    // legitimately name the same entity -- an order push and a buyer-detail
    // capture are both keyed on the order id -- and matching on the id alone
    // would have the second silently replace the first, so the order never
    // went up at all. It would also throw here the moment two such rows
    // existed, because `getSingleOrNull` is single-or-null and not first.
    final existing =
        await (db.select(db.outbox)..where(
              (o) =>
                  o.entityId.equals(entityId) & o.entityType.equals(entityType),
            ))
            .getSingleOrNull();

    await db.enqueueOutbox(
      OutboxCompanion.insert(
        id: existing?.id ?? newId(),
        entityType: entityType,
        entityId: entityId,
        payload: jsonEncode(payload),
        // Keeps its place in the queue. A quote edited at 4pm should not
        // overtake one finished at 2pm that is still waiting.
        createdAt: existing?.createdAt ?? clock(),
      ),
    );
  }

  /// Sends everything waiting, oldest first.
  ///
  /// Stops at the first network failure rather than working through a queue
  /// against a connection that is not there. Whatever went up before it stays
  /// up â€” the server has those quotes, and the rows are gone.
  Future<DrainReport> drain(Credentials credentials) async {
    final sent = <String>[];
    final parked = <String>[];
    final disagreed = <String>[];

    for (final row in await db.pendingOutbox()) {
      final body = jsonDecode(row.payload) as Map<String, dynamic>;

      // One queue, seven kinds of work. None of them can wait behind another
      // that is failing â€” they drain in the order they happened, which is the
      // order they matter in.
      final SyncResult<Object> result = switch (row.entityType) {
        'payment' => await api.pushPayment(credentials.token, body),
        'order' => await api.pushOrder(credentials.token, body),
        'order_status' => await api.pushStatusChange(credentials.token, body),
        'buyer_details' => await api.pushBuyerDetails(credentials.token, body),
        'site_details' => await api.pushSiteDetails(credentials.token, body),
        'measurement' => await api.pushMeasurement(credentials.token, body),
        'lock' => await api.pushLock(credentials.token, body),
        'deposit_prompt' => await api.pushDepositPrompt(
          credentials.token,
          body,
        ),
        'library_submission' => await api.pushLibrarySubmission(
          credentials.token,
          body,
        ),
        _ => await api.pushQuote(credentials.token, body),
      };

      switch (result) {
        case SyncOk(value: final response):
          // `duplicate: true` is a success. It means an earlier attempt landed
          // and the response never made it back, which is exactly what this
          // design expects to happen and must not treat as an error â€” a row
          // that reports failure on a quote the server already has would be
          // retried forever and never drain.
          if (response is ReceiptIssued) {
            // The one number the device may not invent, written back the
            // moment the server hands it over.
            await db.settlePayment(
              paymentId: row.entityId,
              receiptNo: response.receiptNo,
              at: clock(),
            );
            await db.dropOutbox(row.id);
          } else if (response is OrderAccepted) {
            // The order number, for the same reason as a receipt number.
            await db.settleOrder(
              orderId: row.entityId,
              orderNo: response.orderNo,
              at: clock(),
            );
            await db.dropOutbox(row.id);
            if (!response.fullyAccepted) {
              // The order landed and the money is safe, but the server would
              // not take all of it. Surfaced rather than swallowed: a status
              // it refused means the two have drifted, and an override it
              // refused means a price moved on one handset with no audit row
              // anywhere else.
              disagreed.add(row.entityId);
            }
          } else if (response is LockAccepted) {
            await db.settleLock(lockId: row.entityId, at: clock());
            await db.dropOutbox(row.id);
            if (response.clashed) {
              // Another handset already held this category for this customer.
              // Both RM300s are real; the first hold keeps pricing and this one
              // is parked server-side. Surfaced rather than swallowed, because
              // one of the two payments needs refunding and only a person can
              // decide which (Â§13 B10).
              disagreed.add(row.entityId);
            }
          } else if (response is PromptRecorded) {
            await db.settleDepositPrompt(promptId: row.entityId, at: clock());
            await db.dropOutbox(row.id);
          } else if (response is UnitTypeSubmissionAccepted) {
            // Nothing local to settle -- unlike a payment or an order, a
            // submission has no number that comes back to write down. It
            // either exists on the server now or it already did.
            await db.dropOutbox(row.id);
          } else if (response is StatusAccepted) {
            await db.settleOrderEvent(eventId: row.entityId, at: clock());
            await db.dropOutbox(row.id);
            if (!response.accepted) {
              disagreed.add(row.entityId);
            }
          } else if (response is BuyerDetailsAccepted) {
            await db.dropOutbox(row.id);
            if (response.refusedBecause != null) {
              // A `stale` refusal means a newer capture already landed and
              // this one is moot; `unknown_order` means the capture is lost
              // until somebody looks. Either way it must not read as a
              // silent success — CLAUDE.md's promise that a stale push
              // "reads as a failure" only ever held for the dashboard's own
              // correction form until this branch existed.
              disagreed.add(row.entityId);
            }
          } else if (response is SiteDetailsAccepted) {
            await db.dropOutbox(row.id);
            if (response.refusedBecause != null) {
              // `stale`: the office typed something newer, which stands.
              // `unknown_order`: the capture arrived before its order. Either
              // way it must not read as a silent success.
              disagreed.add(row.entityId);
            }
          } else if (response is MeasurementAccepted) {
            await db.dropOutbox(row.id);
            if (response.refusedBecause != null) {
              // A `stale` refusal means a newer tape reading already landed;
              // `unknown_order`/`unknown_line` mean the push arrived before
              // what it refers to, and this measurement is lost until
              // somebody remeasures. Flagged rather than swallowed, the same
              // pattern as the buyer-details branch above.
              disagreed.add(row.entityId);
            }
          } else {
            await db.completeOutbox(row.id, row.entityId, clock());
            if (response is PushResponse && !response.agreed) {
              disagreed.add(row.entityId);
            }
          }
          sent.add(row.entityId);

        case SyncFailed(:final failure, :final detail):
          await _recordFailure(row, detail);

          switch (failure) {
            case SyncFailure.offline:
            case SyncFailure.unauthenticated:
              // Nothing behind this row will fare better. Stop, keep the queue
              // intact, and try again on the next connection.
              return DrainReport(
                sent: sent,
                parked: parked,
                disagreed: disagreed,
                failure: failure,
              );

            case SyncFailure.forbidden:
            case SyncFailure.serverError:
              // This row is the problem, not the connection â€” a rejected
              // payload, or a rate card version this server has never
              // published. Park it once it has had enough tries and carry on,
              // so one bad quote does not hold up the rest of the day's work.
              if (row.attempts + 1 >= kMaxAttempts) {
                await _park(row);
                parked.add(row.entityId);
              }
          }
      }
    }

    return DrainReport(sent: sent, parked: parked, disagreed: disagreed);
  }

  /// Rows that have stopped being retried, for the diagnostics screen.
  ///
  /// They are never deleted automatically. Someone has to look at them,
  /// because each one is an order the office does not know about.
  Future<List<OutboxRow>> parked() =>
      (db.select(db.outbox)..where((o) => o.parkedAt.isNotNull())).get();

  /// Puts a parked row back in the queue â€” after a fix at the other end.
  Future<void> retryParked(String outboxId) =>
      (db.update(db.outbox)..where((o) => o.id.equals(outboxId))).write(
        const OutboxCompanion(
          parkedAt: Value(null),
          attempts: Value(0),
          lastError: Value(null),
        ),
      );

  Future<void> _recordFailure(OutboxRow row, String detail) =>
      (db.update(db.outbox)..where((o) => o.id.equals(row.id))).write(
        OutboxCompanion(
          attempts: Value(row.attempts + 1),
          lastAttemptAt: Value(clock()),
          lastError: Value(detail),
        ),
      );

  Future<void> _park(OutboxRow row) =>
      (db.update(db.outbox)..where((o) => o.id.equals(row.id))).write(
        OutboxCompanion(parkedAt: Value(clock())),
      );
}

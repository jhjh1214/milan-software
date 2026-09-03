/// The push side. §9.2.
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
  /// accepted (§9.4) — this is a review task, not a failure.
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
  Future<void> enqueueQuote(
    String quoteId,
    Map<String, dynamic> payload,
  ) async {
    final existing = await (db.select(
      db.outbox,
    )..where((o) => o.entityId.equals(quoteId))).getSingleOrNull();

    await db.enqueueOutbox(
      OutboxCompanion.insert(
        id: existing?.id ?? newId(),
        entityType: 'quote',
        entityId: quoteId,
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
  /// up — the server has those quotes, and the rows are gone.
  Future<DrainReport> drain(Credentials credentials) async {
    final sent = <String>[];
    final parked = <String>[];
    final disagreed = <String>[];

    for (final row in await db.pendingOutbox()) {
      final result = await api.pushQuote(
        credentials.token,
        jsonDecode(row.payload) as Map<String, dynamic>,
      );

      switch (result) {
        case SyncOk(value: final response):
          // `duplicate: true` is a success. It means an earlier attempt landed
          // and the response never made it back, which is exactly what this
          // design expects to happen and must not treat as an error — a row
          // that reports failure on a quote the server already has would be
          // retried forever and never drain.
          await db.completeOutbox(row.id, row.entityId, clock());
          sent.add(row.entityId);
          if (!response.agreed) disagreed.add(row.entityId);

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
              // This row is the problem, not the connection — a rejected
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

  /// Puts a parked row back in the queue — after a fix at the other end.
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

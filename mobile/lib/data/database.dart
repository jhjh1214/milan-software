/// Local persistence. Drift over SQLite, per CLAUDE.md — relational, not
/// key-value.
///
/// SPEC.md §8.1: "The app will be backgrounded mid-quote by a phone call. Every
/// keystroke persists locally. Reopening returns to the exact window." A dropped
/// phone at a fair must cost nothing.
///
/// ## Conventions this schema obeys
///
/// - **Ids are client-generated UUID v4.** Two part-timers offline at one fair
///   must never collide, so nothing waits on a server for an id.
/// - **Lengths are `_tmm`** — integer tenths of a millimetre. A column named
///   `_mm` is a bug.
/// - **Money is `_sen`** — integer. No `REAL` column ever holds currency.
/// - **Syncing tables carry `synced_at`**, null until the server has it.
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// A quotation in progress, or one already converted to an order.
///
/// Phase 1 kept this in memory and lost it on force-quit. Phase 2 does not.
@DataClassName('QuoteRow')
class Quotes extends Table {
  /// Client-generated UUID v4.
  TextColumn get id => text()();

  /// Which rate card priced this quote. Pinned at creation so a later
  /// publish cannot silently reprice work already shown to a customer.
  IntColumn get rateCardVersion => integer()();

  /// `standard` or `mvp`.
  TextColumn get tier => text().withDefault(const Constant('standard'))();

  /// The user's language when the quote was made, for reprinting it the same
  /// way later.
  TextColumn get language => text().withDefault(const Constant('zh'))();

  /// Free-text customer name. A full customer record arrives with Phase 4.
  TextColumn get customerName => text().nullable()();
  TextColumn get customerPhone => text().nullable()();

  /// The delivery zone charged on this quote, if any.
  ///
  /// SPEC.md §4.1: the charge is driven by the delivery address, not by any
  /// line, and must be surfaced **before** the total — never after the customer
  /// has already agreed a number.
  TextColumn get deliveryZoneId => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Null until the server has this row. Phase 3.
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One window on a quote.
///
/// Stores what was *entered*, not what was computed. Prices are derived by the
/// engine on read, so a rate-card correction reprices old drafts rather than
/// leaving them frozen at a number nobody can reproduce.
@DataClassName('QuoteLineRow')
class QuoteLines extends Table {
  TextColumn get id => text()();
  TextColumn get quoteId => text().references(Quotes, #id)();

  /// Display order within the quote.
  IntColumn get sortOrder => integer()();

  TextColumn get room => text()();
  TextColumn get variant => text()();

  /// Null means the customer has not chosen a material yet — the fair case.
  TextColumn get materialKey => text().nullable()();

  TextColumn get layer => text()();

  /// The line this one is an upgrade to, if any.
  ///
  /// A special track, a motor or a box is an extra charge **on top of** the
  /// curtain or blind it belongs to (A16), so it is a child line rather than a
  /// separate window. It carries a copy of its parent's dimensions — instantiate
  /// rather than reference, so editing the parent later cannot silently
  /// reprice a line the customer already agreed.
  TextColumn get parentLineId => text().nullable()();

  /// Tenths of a millimetre. Never millimetres.
  IntColumn get widthTmm => integer()();
  IntColumn get heightTmm => integer().nullable()();

  /// Exactly what the user typed, so §5.5 can show entered beside billed
  /// without inventing precision that was never entered.
  TextColumn get rawWidth => text()();
  TextColumn get rawHeight => text()();

  IntColumn get quantity => integer().withDefault(const Constant(1))();

  /// On-device path to the photo of this window.
  ///
  /// The path only, not the bytes: a 3MB JPEG in a SQLite row bloats every
  /// query that touches the line. §7 keeps `local_path` until upload and
  /// `remote_key` after, and the upload half arrives with sync in Phase 3.
  TextColumn get photoPath => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One RM300, holding one category's prices for twelve months. SPEC.md §6.1.
///
/// **Rows are never edited into existence.** `openCategoryLock` in
/// `pricing/rate_lock.dart` is the only thing that builds one, and it refuses
/// outside a fair and below the minimum, so a screen cannot open a lock the
/// business does not sell.
///
/// Held on the device as well as the server because the resolver has to work
/// with no signal: a customer who deposited at the August fair and walks into
/// the showroom in March must be priced correctly on a handset that has not
/// synced today.
@DataClassName('CategoryLockRow')
class CategoryLocks extends Table {
  TextColumn get id => text()();

  /// Whose lock it is. The lock follows the **customer**, not the order — a
  /// hold bought at last August's fair prices a line added months later.
  TextColumn get customerId => text()();

  /// `curtain`, `flooring` or `wallpaper`. Three, not seven: blinds and tracks
  /// ride the curtain deposit.
  TextColumn get category => text()();

  /// The payment that bought it, so a refund can find the lock it cancels.
  TextColumn get depositPaymentId => text().nullable()();

  /// Pinned **both**, at deposit time. Pinning only the version silently
  /// reprices this customer when the promo percentage moves.
  IntColumn get heldRateCardVersion => integer()();

  /// Exact rational, stored in this type's own `toString` notation — `0`,
  /// `1/10`. Never a float: a percentage of a price is money.
  TextColumn get heldDiscountPct => text().withDefault(const Constant('0'))();

  /// The **last day** the hold is good for, inclusive.
  DateTimeColumn get heldUntil => dateTime()();

  /// `active`, `expired`, `cancelled` or `refunded`.
  TextColumn get status => text().withDefault(const Constant('active'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Every time the category prompt was shown, and what was pressed. §6.2.
///
/// **APPEND ONLY.** The declined-deposit report is the point: it tells the boss
/// what fairs are leaving on the table, and it only exists if a decline is
/// recorded as deliberately as a sale. A row is never updated — pressing a
/// different button later is a second row.
@DataClassName('DepositPromptRow')
class DepositPrompts extends Table {
  TextColumn get id => text()();
  TextColumn get quoteId => text()();
  TextColumn get category => text()();

  /// `collected`, `declined`, `lines_removed` or `dismissed`. Dismissed is kept
  /// distinct from declined: "they said no" and "nobody asked properly" are
  /// different problems, and only one of them is the customer's.
  TextColumn get choice => text()();

  /// What the quote was worth in this category when the question was asked, so
  /// the report can say what was left on the table rather than only how often.
  IntColumn get categorySubtotalSen =>
      integer().withDefault(const Constant(0))();

  TextColumn get byUserId => text().nullable()();
  DateTimeColumn get at => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Work waiting to reach the server. §9.2.
///
/// The whole of the push side is this table plus a drainer. Nothing is sent
/// synchronously and nothing blocks the UI on a network call: a quote is
/// finished, a row lands here, and it goes up whenever there is signal — which
/// at a fair might be that evening, in the car.
///
/// **Drained FIFO.** Order matters because a later row can depend on an earlier
/// one, and because a queue that reorders is a queue nobody can reason about
/// when it goes wrong.
///
/// The row's [entityId] is the quote's own client-generated UUID, which is what
/// makes the push idempotent: the server has seen that id or it has not. A
/// retry after a connection dropped mid-request is therefore free, and the
/// device never has to know whether the first attempt landed.
@DataClassName('OutboxRow')
class Outbox extends Table {
  TextColumn get id => text()();

  /// `quote` for now. Payments and photos join it in Phase 4.
  TextColumn get entityType => text()();

  /// The entity's client-generated id. The server is idempotent on it.
  TextColumn get entityId => text()();

  /// The whole request body, serialised at enqueue time.
  ///
  /// Frozen rather than rebuilt at send time on purpose: what goes up is what
  /// the customer was shown, not what the quote has since been edited into.
  TextColumn get payload => text()();

  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();

  /// Why the last attempt failed. For the diagnostics screen; never shown raw
  /// to a part-timer.
  TextColumn get lastError => text().nullable()();

  /// Set when a row has failed so many times that it is clearly not going to
  /// work. It stops being retried but is **never deleted** — it is somebody's
  /// order, and it needs looking at rather than losing.
  DateTimeColumn get parkedAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [Quotes, QuoteLines, Outbox, CategoryLocks, DepositPrompts],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'milan_quote'));

  /// Store timestamps as ISO-8601 text in UTC, not as unix seconds.
  ///
  /// Two reasons. SPEC.md §7 requires timestamps stored UTC and displayed
  /// Asia/Kuala_Lumpur, and unix-seconds columns carry no zone at all. And
  /// second precision is too coarse for `updated_at` — two lines added in the
  /// same second tie, and after a crash `latestQuote` could reopen the wrong
  /// draft.
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      // Written as real migrations rather than a wipe, because by the time
      // these ship a part-timer may already have an unsynced quote on their
      // phone.
      //
      // v2: upgrade lines — a special track or motor charged on top of the
      //     curtain it belongs to (A16).
      // v3: the order-level delivery zone charge (§4.1).
      if (from < 2) {
        await m.addColumn(quoteLines, quoteLines.parentLineId);
      }
      if (from < 3) {
        await m.addColumn(quotes, quotes.deliveryZoneId);
      }
      // v4: a photo per window (§8.1).
      if (from < 4) {
        await m.addColumn(quoteLines, quoteLines.photoPath);
      }
      // v5: the outbox (§9.2). Created rather than backfilled — a quote taken
      // before sync existed was never destined for a server.
      if (from < 5) {
        await m.createTable(outbox);
      }
      // v6: rate locks and the category prompt log (§6.1, §6.2).
      if (from < 6) {
        await m.createTable(categoryLocks);
        await m.createTable(depositPrompts);
      }
    },
    beforeOpen: (details) async {
      // Drift does not enable foreign keys by default, and without this a line
      // can outlive the quote it belongs to.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// The quote currently being worked on, if there is one.
  ///
  /// Phase 1 has no order concept yet, so a session has at most one draft.
  Future<QuoteRow?> latestQuote() =>
      (select(quotes)
            ..orderBy([(q) => OrderingTerm.desc(q.updatedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<List<QuoteLineRow>> linesFor(String quoteId) =>
      (select(quoteLines)
            ..where((l) => l.quoteId.equals(quoteId))
            ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
          .get();

  /// Watches a quote's lines so the UI updates without polling.
  Stream<List<QuoteLineRow>> watchLines(String quoteId) =>
      (select(quoteLines)
            ..where((l) => l.quoteId.equals(quoteId))
            ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
          .watch();

  /// Adds a line and touches the quote's `updated_at` in **one** transaction.
  ///
  /// Both or neither. A line that lands while its quote's timestamp does not
  /// would make `latestQuote` pick the wrong draft after a crash.
  Future<void> addLine(QuoteLinesCompanion line, String quoteId) =>
      transaction(() async {
        await into(quoteLines).insert(line);
        await (update(quotes)..where((q) => q.id.equals(quoteId))).write(
          QuotesCompanion(updatedAt: Value(DateTime.now())),
        );
      });

  Future<QuoteLineRow?> lineById(String lineId) =>
      (select(quoteLines)..where((l) => l.id.equals(lineId))).getSingleOrNull();

  Future<void> deleteLine(String lineId) =>
      (delete(quoteLines)..where((l) => l.id.equals(lineId))).go();

  Future<void> clearAll() => transaction(() async {
    await delete(quoteLines).go();
    await delete(quotes).go();
    await delete(outbox).go();
  });

  /// The next rows to send, oldest first. §9.2 drains FIFO.
  ///
  /// Parked rows are skipped: one bad row must not stop every quote behind it
  /// from reaching the office.
  Future<List<OutboxRow>> pendingOutbox({int limit = 50}) =>
      (select(outbox)
            ..where((o) => o.parkedAt.isNull())
            ..orderBy([(o) => OrderingTerm.asc(o.createdAt)])
            ..limit(limit))
          .get();

  /// How many quotes are waiting to send, for the badge in the app bar.
  ///
  /// A one-shot count rather than a live stream. The depth only moves when
  /// this app enqueues or drains, and both are our own code paths, so watching
  /// buys nothing — while a live query holds a subscription for the life of the
  /// screen and leaves drift's teardown timer pending when the tree is
  /// unmounted, which every widget test then trips over.
  Future<int> outboxDepth() async {
    final count = outbox.id.count();
    final row =
        await (selectOnly(outbox)
              ..addColumns([count])
              ..where(outbox.parkedAt.isNull()))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> enqueueOutbox(OutboxCompanion row) =>
      into(outbox).insert(row, mode: InsertMode.insertOrReplace);

  /// Removes a row the server has confirmed, and stamps the quote as synced,
  /// in **one** transaction.
  ///
  /// Both or neither: a row deleted while the quote's `synced_at` stayed null
  /// would leave a quote that looks unsent and will never be sent again.
  Future<void> completeOutbox(String outboxId, String quoteId, DateTime at) =>
      transaction(() async {
        await (delete(outbox)..where((o) => o.id.equals(outboxId))).go();
        await (update(quotes)..where((q) => q.id.equals(quoteId))).write(
          QuotesCompanion(syncedAt: Value(at)),
        );
      });
}

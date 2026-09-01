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

  /// Tenths of a millimetre. Never millimetres.
  IntColumn get widthTmm => integer()();
  IntColumn get heightTmm => integer().nullable()();

  /// Exactly what the user typed, so §5.5 can show entered beside billed
  /// without inventing precision that was never entered.
  TextColumn get rawWidth => text()();
  TextColumn get rawHeight => text()();

  IntColumn get quantity => integer().withDefault(const Constant(1))();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Quotes, QuoteLines])
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
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
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

  Future<void> deleteLine(String lineId) =>
      (delete(quoteLines)..where((l) => l.id.equals(lineId))).go();

  Future<void> clearAll() => transaction(() async {
    await delete(quoteLines).go();
    await delete(quotes).go();
  });
}

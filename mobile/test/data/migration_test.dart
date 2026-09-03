/// The migrations actually run, against a database that already has data in it.
///
/// CLAUDE.md's reason for writing real migrations rather than wiping:
///
/// > by the time these ship a part-timer may already have an unsynced quote on
/// > their phone.
///
/// Which makes an untested migration the same shape of risk as an untested
/// backup: it is fine right up until the one morning it is not, and the cost
/// lands on somebody standing at a fair.
///
/// The old schema here is built by taking the current one and undoing exactly
/// what the step added. For an additive migration that *is* the previous
/// schema, and it exercises the real `onUpgrade` path rather than a
/// reimplementation of it.
///
/// ## What this does not reach yet
///
/// Only the v9 → v10 step. The earlier ones cannot be exercised without a real
/// database at those versions, and this repo has no captured schemas — `dart
/// run drift_dev schema dump` writes them, and v10 should be the first version
/// to have one so that v11 can be verified properly.
///
/// That matters unevenly. Mutating the `from < 8` and `from < 9` guards to be
/// too loose does **not** fail this suite, because `Migrator.createTable`
/// issues `CREATE TABLE IF NOT EXISTS` and re-running it is harmless. The same
/// mistake on the `addColumn` steps — v2, v3, v4 and v7 — would throw on
/// launch with a duplicate column, and nothing here would catch it. Those four
/// are the ones a snapshot would earn its keep on.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('milan_migration');
    file = File('${dir.path}/milan.sqlite');
  });

  tearDown(() {
    // A test that fails before closing leaves the file locked on Windows.
    // Losing a temp directory is not worth masking the failure that caused it.
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  /// Opens the database at [file], forcing the migration to run.
  Future<AppDatabase> open() async {
    final db = AppDatabase(NativeDatabase(file));
    // Drift is lazy: nothing migrates until something is asked for.
    await db.customSelect('SELECT 1').get();
    return db;
  }

  Future<List<String>> tablesIn(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "ORDER BY name",
        )
        .get();
    return [for (final r in rows) r.read<String>('name')];
  }

  /// A quote, an order and one line, so a foreign key has something to point
  /// at.
  Future<void> seedOrderLine(AppDatabase db) async {
    final at = DateTime(2026, 8, 29, 9);
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q-1',
            rateCardVersion: 1,
            createdAt: at,
            updatedAt: at,
          ),
        );
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: 'o-1',
            quoteId: 'q-1',
            channel: 'fair',
            pinnedRateCardVersion: 1,
            estimateTotalSen: 96000,
            confirmedAt: at,
          ),
        );
    await db
        .into(db.orderLines)
        .insert(
          OrderLinesCompanion.insert(
            id: 'ol-1',
            orderId: 'o-1',
            quoteLineId: 'ql-1',
            sortOrder: 0,
            room: 'Living room',
            variant: 'night_curtain_sfold',
            layer: 'night',
            estWidthTmm: 36576,
            appliedRuleId: 'rule-1',
            appliedRateCardVersion: 1,
            standardRateSen: 8000,
            rateSen: 8000,
            billedQty: '12',
            billedUnit: 'ft',
            lineTotalSen: 96000,
          ),
        );
  }

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      );

  test('a fresh database opens at the current version', () async {
    final db = await open();
    expect(await userVersion(db), 10);
    expect(await tablesIn(db), contains('price_overrides'));
    await db.close();
  });

  test('v9 upgrades to v10 without touching what was already there', () async {
    // Build the current schema, put a quote on it, then wind the file back to
    // what a handset in the field is actually carrying.
    final before = await open();
    await before
        .into(before.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q-already-here',
            rateCardVersion: 1,
            customerName: const Value('Ah Lian'),
            createdAt: DateTime(2026, 8, 29, 9),
            updatedAt: DateTime(2026, 8, 29, 9),
          ),
        );
    await before.customStatement('DROP TABLE price_overrides');
    await before.customStatement('PRAGMA user_version = 9');
    await before.close();

    final after = await open();
    expect(
      await userVersion(after),
      10,
      reason: 'the upgrade should have run and recorded itself',
    );
    expect(
      await tablesIn(after),
      contains('price_overrides'),
      reason: 'v10 creates the price override audit log (§6.5)',
    );

    final quote = await (after.select(
      after.quotes,
    )..where((q) => q.id.equals('q-already-here'))).getSingle();
    expect(
      quote.customerName,
      'Ah Lian',
      reason: 'the unsynced quote on the part-timer phone has to survive',
    );

    await after.close();
  });

  test('the new table is usable, and keeps its constraints', () async {
    // A migration that creates a table with the wrong columns passes a
    // "does it exist" check and fails on the first write, which is at a fair.
    // The foreign key matters as much: an audit row pointing at no line is a
    // row the weekly review cannot explain.
    final before = await open();
    await before.customStatement('DROP TABLE price_overrides');
    await before.customStatement('PRAGMA user_version = 9');
    await before.close();

    final after = await open();
    await seedOrderLine(after);

    await after
        .into(after.priceOverrides)
        .insert(
          PriceOverridesCompanion.insert(
            id: 'ov-1',
            orderLineId: 'ol-1',
            orderId: 'o-1',
            beforeSen: 55200,
            afterSen: 50000,
            reason: 'matched a competitor quote',
            adminUserId: 'u-boss',
            at: DateTime(2026, 8, 29, 15),
          ),
        );

    final row = await after.select(after.priceOverrides).getSingle();
    expect(row.beforeSen, 55200);
    expect(row.adminUserId, 'u-boss');

    await expectLater(
      after
          .into(after.priceOverrides)
          .insert(
            PriceOverridesCompanion.insert(
              id: 'ov-2',
              orderLineId: 'no-such-line',
              orderId: 'o-1',
              beforeSen: 55200,
              afterSen: 50000,
              reason: 'matched a competitor quote',
              adminUserId: 'u-boss',
              at: DateTime(2026, 8, 29, 15),
            ),
          ),
      throwsA(anything),
      reason:
          'the migrated table has to carry its foreign key, not just its '
          'columns',
    );

    await after.close();
  });

  test('opening an already-current database migrates nothing', () async {
    // The upgrade block is guarded by `from < 10`. If it were not, a second
    // open would try to create a table that exists and throw on launch.
    final first = await open();
    await first.close();

    final second = await open();
    expect(await userVersion(second), 10);
    expect(await tablesIn(second), contains('price_overrides'));
    await second.close();
  });

  test(
    'foreign keys are on after a migration, not only on a fresh open',
    () async {
      // `beforeOpen` turns them on; SQLite defaults them off per connection. A
      // migrated handset with them off would accept an order line pointing at no
      // order, and nothing would notice until a report came up short.
      final before = await open();
      await before.customStatement('DROP TABLE price_overrides');
      await before.customStatement('PRAGMA user_version = 9');
      await before.close();

      final after = await open();
      final on = (await after.customSelect('PRAGMA foreign_keys').getSingle())
          .read<int>('foreign_keys');
      expect(on, 1);
      await after.close();
    },
  );
}

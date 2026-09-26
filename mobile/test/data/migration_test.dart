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
            estWidthTmm: const Value(36576),
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

  /// Undoes exactly what v13 added: where a line's dimensions came from
  /// (SPEC.md Phase 8's Property / Project / Unit Library).
  Future<void> undoV13(AppDatabase db) async {
    for (final column in const [
      'source_project_id',
      'source_unit_type_id',
      'source_version',
    ]) {
      await db.customStatement('ALTER TABLE quote_lines DROP COLUMN $column');
    }
    for (final column in const [
      'measurement_source',
      'source_project_id',
      'source_unit_type_id',
      'source_version',
    ]) {
      await db.customStatement('ALTER TABLE order_lines DROP COLUMN $column');
    }
  }

  /// Undoes exactly what v12 added: the buyer's details for an e-invoice.
  /// Undoes exactly what v16 added: where a visit is, on quotes and orders.
  Future<void> undoV16(AppDatabase db) async {
    for (final column in const [
      'site_address',
      'site_postcode',
      'site_ready_from',
    ]) {
      await db.customStatement('ALTER TABLE quotes DROP COLUMN $column');
    }
    for (final column in const [
      'site_address',
      'site_postcode',
      'site_ready_from',
      'site_captured_at',
    ]) {
      await db.customStatement('ALTER TABLE orders DROP COLUMN $column');
    }
  }

  Future<void> undoV12(AppDatabase db) async {
    for (final column in const [
      'buyer_tin',
      'buyer_id_type',
      'buyer_id_number',
      'buyer_address_line1',
      'buyer_address_line2',
      'buyer_city',
      'buyer_state',
      'buyer_postcode',
      'buyer_msic_code',
      'einvoice_requested',
    ]) {
      await db.customStatement('ALTER TABLE orders DROP COLUMN $column');
    }
  }

  /// Undoes exactly what v11 added: the six columns for what the tape priced.
  ///
  /// `ALTER TABLE ... DROP COLUMN` rather than a rebuild, so what is left is
  /// exactly the v10 table and the real `onUpgrade` runs against it.
  Future<void> undoV11(AppDatabase db) async {
    for (final column in const [
      'final_billed_qty',
      'final_billed_unit',
      'final_rule_id',
      'final_band_label',
      'final_rate_sen',
      'final_line_total_sen',
    ]) {
      await db.customStatement('ALTER TABLE order_lines DROP COLUMN $column');
    }
  }

  /// Undoes exactly what v10 added: the price override audit log.
  Future<void> undoV10(AppDatabase db) async {
    await db.customStatement('DROP TABLE price_overrides');
  }

  /// Undoes exactly what v14 added: a part-timer's own floor-plan
  /// submission (SPEC.md Phase 8's last open item).
  Future<void> undoV14(AppDatabase db) async {
    await db.customStatement('DROP TABLE library_submissions');
  }

  /// Undoes exactly what v15 added: a room-sourced flooring line's area.
  ///
  /// v15 also widens `width_tmm`/`est_width_tmm` to nullable, but that half
  /// needs no undoing here -- `alterTable` recreates the table from the
  /// column list on the CURRENT `AppDatabase` class regardless of what the
  /// starting table enforced, so it copies existing (always non-null) row
  /// data forward correctly either way. What genuinely has to be absent
  /// before the upgrade runs is the new column, the same as every other
  /// `addColumn`-shaped step above.
  Future<void> undoV15(AppDatabase db) async {
    await db.customStatement(
      'ALTER TABLE quote_lines DROP COLUMN direct_area_sqft',
    );
    await db.customStatement(
      'ALTER TABLE order_lines DROP COLUMN direct_area_sqft',
    );
  }

  /// Winds a current file back to [version], undoing each step in turn.
  ///
  /// It has to compose. Winding back to 9 by undoing only v10 leaves v11's
  /// columns in place, and the upgrade then runs `addColumn` against a table
  /// that already has them -- which throws, and is exactly the failure this
  /// suite exists to catch, arriving as a false one.
  Future<void> windBackTo(AppDatabase db, int version) async {
    if (version < 16) await undoV16(db);
    if (version < 15) await undoV15(db);
    if (version < 14) await undoV14(db);
    if (version < 13) await undoV13(db);
    if (version < 12) await undoV12(db);
    if (version < 11) await undoV11(db);
    if (version < 10) await undoV10(db);
    await db.customStatement('PRAGMA user_version = $version');
  }

  test('a fresh database opens at the current version', () async {
    final db = await open();
    expect(await userVersion(db), 16);
    expect(await tablesIn(db), contains('price_overrides'));
    expect(await tablesIn(db), contains('library_submissions'));
    await db.close();
  });

  test('v9 upgrades all the way, without touching what was there', () async {
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
    await windBackTo(before, 9);
    await before.close();

    final after = await open();
    expect(
      await userVersion(after),
      16,
      reason: 'every step from 9 should have run, and recorded itself',
    );
    expect(
      await tablesIn(after),
      contains('price_overrides'),
      reason: 'v10 creates the price override audit log (§6.5)',
    );
    // A handset can be several versions behind — it has been in a drawer, or
    // the fair was the last time it had signal. Every step in between has to
    // run, not just the last one.
    final columns = await after
        .customSelect("PRAGMA table_info('order_lines')")
        .get();
    expect(
      [for (final c in columns) c.read<String>('name')],
      contains('final_line_total_sen'),
      reason: 'v11 adds what the tape priced (§11 Phase 6)',
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
    await windBackTo(before, 9);
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
    expect(await userVersion(second), 16);
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
      await windBackTo(before, 9);
      await before.close();

      final after = await open();
      final on = (await after.customSelect('PRAGMA foreign_keys').getSingle())
          .read<int>('foreign_keys');
      expect(on, 1);
      await after.close();
    },
  );

  group('v10 → v11 — what the tape priced (§11 Phase 6)', () {
    test('the order line already on the handset survives it', () async {
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 10);
      await before.close();

      final after = await open();
      expect(
        await userVersion(after),
        16,
        reason: 'the upgrade should have run and recorded itself',
      );

      final line = await (after.select(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).getSingle();

      expect(
        line.lineTotalSen,
        96000,
        reason: 'the quoted total is untouched — §6.3 keeps both',
      );
      expect(
        line.finalLineTotalSen,
        null,
        reason: 'nothing has been measured, so there is no final total',
      );
      expect(line.finalBilledQty, null);

      await after.close();
    });

    test('the new columns are writable, beside the estimate', () async {
      // A migration that adds a column of the wrong type passes a "does it
      // exist" check and fails on the first write, which is in a house.
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 10);
      await before.close();

      final after = await open();
      await (after.update(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).write(
        const OrderLinesCompanion(
          finalBilledQty: Value('4375/381'),
          finalBilledUnit: Value('ft'),
          finalRuleId: Value('night-curtain-lo'),
          finalBandLabel: Value('Up to 10ft'),
          finalRateSen: Value(4600),
          finalLineTotalSen: Value(52822),
        ),
      );

      final line = await (after.select(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).getSingle();

      // The exact rational, stored as text. A double column would have taken
      // this and given back something that is not 4375/381.
      expect(line.finalBilledQty, '4375/381');
      expect(line.finalLineTotalSen, 52822);
      expect(
        line.lineTotalSen,
        96000,
        reason: 'the final is written beside the estimate, never over it',
      );

      await after.close();
    });

    test('running the upgrade twice does not throw', () async {
      // The point of this whole group. `addColumn` is not idempotent: if the
      // `from < 11` guard were ever loosened, this would fail with a duplicate
      // column name, on launch, on a handset that already migrated.
      final first = await open();
      await first.close();

      final second = await open();
      expect(await userVersion(second), 16);
      await second.close();
    });
  });

  group('v11 → v12 — the buyer\'s details (§10.3)', () {
    test('the order already on the handset survives it', () async {
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 11);
      await before.close();

      final after = await open();
      expect(await userVersion(after), 16);

      final order = await (after.select(
        after.orders,
      )..where((o) => o.id.equals('o-1'))).getSingle();

      expect(
        order.estimateTotalSen,
        96000,
        reason: 'the money on an order in the field is untouched',
      );
      expect(
        order.buyerTin,
        null,
        reason: 'nobody was asked, because there was nowhere to put the answer',
      );
      expect(
        order.einvoiceRequested,
        isFalse,
        reason: 'a bool column with no value must not read as true',
      );

      await after.close();
    });

    test('the new columns are writable', () async {
      // A migration that adds a column of the wrong type passes a "does it
      // exist" check and fails on the first write, which is in front of a
      // customer reading out their IC number.
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 11);
      await before.close();

      final after = await open();
      await (after.update(
        after.orders,
      )..where((o) => o.id.equals('o-1'))).write(
        const OrdersCompanion(
          buyerTin: Value('C12345678901'),
          buyerIdType: Value('nric'),
          buyerIdNumber: Value('880101105566'),
          buyerAddressLine1: Value('12 Jalan Merdeka'),
          buyerCity: Value('Melaka'),
          buyerState: Value('Melaka'),
          buyerPostcode: Value('75000'),
          buyerMsicCode: Value('47591'),
          einvoiceRequested: Value(true),
        ),
      );

      final order = await (after.select(
        after.orders,
      )..where((o) => o.id.equals('o-1'))).getSingle();

      expect(order.buyerIdNumber, '880101105566');
      expect(order.buyerPostcode, '75000');
      expect(order.einvoiceRequested, isTrue);

      await after.close();
    });

    test('running the upgrade twice does not throw', () async {
      // `addColumn` is not idempotent. A loosened guard fails with a duplicate
      // column name, on launch, on a handset that already migrated.
      final first = await open();
      await first.close();

      final second = await open();
      expect(await userVersion(second), 16);
      await second.close();
    });
  });

  group('v12 → v13 — where a line\'s dimensions came from (Phase 8)', () {
    test('the order line already on the handset survives it', () async {
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 12);
      await before.close();

      final after = await open();
      expect(await userVersion(after), 16);

      final line = await (after.select(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).getSingle();

      expect(
        line.lineTotalSen,
        96000,
        reason: 'the money on a line in the field is untouched',
      );
      expect(
        line.measurementSource,
        'manual',
        reason:
            'every line before this library existed was typed by hand, and '
            'that is the truth an existing row has to keep reading as',
      );
      expect(line.sourceUnitTypeId, null);

      await after.close();
    });

    test('the new columns are writable, on both tables', () async {
      // A migration that adds a column of the wrong type passes a "does it
      // exist" check and fails on the first write, which is a salesperson
      // picking a unit type mid-quote.
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 12);
      await before.close();

      final after = await open();

      await after
          .into(after.quoteLines)
          .insert(
            QuoteLinesCompanion.insert(
              id: 'ql-2',
              quoteId: 'q-1',
              sortOrder: 0,
              room: 'Living',
              variant: 'night_curtain_sfold',
              layer: 'night',
              widthTmm: const Value(54864),
              rawWidth: '18',
              rawHeight: '',
              createdAt: DateTime(2026, 9, 9, 9),
              sourceProjectId: const Value('p-1'),
              sourceUnitTypeId: const Value('ut-1'),
              sourceVersion: const Value(1),
            ),
          );

      final quoteLine = await (after.select(
        after.quoteLines,
      )..where((l) => l.id.equals('ql-2'))).getSingle();
      expect(quoteLine.sourceProjectId, 'p-1');
      expect(quoteLine.sourceUnitTypeId, 'ut-1');
      expect(quoteLine.sourceVersion, 1);

      await (after.update(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).write(
        const OrderLinesCompanion(
          measurementSource: Value('project_library'),
          sourceProjectId: Value('p-1'),
          sourceUnitTypeId: Value('ut-1'),
          sourceVersion: Value(1),
        ),
      );

      final orderLine = await (after.select(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).getSingle();
      expect(orderLine.measurementSource, 'project_library');
      expect(orderLine.sourceUnitTypeId, 'ut-1');
      expect(
        orderLine.lineTotalSen,
        96000,
        reason: 'setting provenance must not touch the money on the line',
      );

      await after.close();
    });

    test('running the upgrade twice does not throw', () async {
      // `addColumn` is not idempotent. A loosened guard fails with a duplicate
      // column name, on launch, on a handset that already migrated.
      final first = await open();
      await first.close();

      final second = await open();
      expect(await userVersion(second), 16);
      await second.close();
    });
  });

  group('v13 → v14 — a part-timer\'s own floor-plan submission (Phase 8)', () {
    test('the order line already on the handset survives it', () async {
      final before = await open();
      await seedOrderLine(before);
      await windBackTo(before, 13);
      await before.close();

      final after = await open();
      expect(await userVersion(after), 16);

      final line = await (after.select(
        after.orderLines,
      )..where((l) => l.id.equals('ol-1'))).getSingle();
      expect(
        line.lineTotalSen,
        96000,
        reason: 'a new table must not touch money on a line already there',
      );

      await after.close();
    });

    test('the new table is usable', () async {
      // `createTable` is `IF NOT EXISTS`, so a loose `from < 14` guard
      // would not throw the way a loose `addColumn` guard does -- but the
      // table still has to have the right columns, or the first real
      // submission fails at a fair.
      final before = await open();
      await windBackTo(before, 13);
      await before.close();

      final after = await open();
      await after
          .into(after.librarySubmissions)
          .insert(
            LibrarySubmissionsCompanion.insert(
              id: 'ut-device-1',
              projectId: 'p-1',
              projectName: 'ABC Development',
              unitTypeName: 'Type C',
              createdAt: DateTime(2026, 9, 12, 10),
            ),
          );

      final row = await (after.select(
        after.librarySubmissions,
      )..where((s) => s.id.equals('ut-device-1'))).getSingle();
      expect(row.projectId, 'p-1');
      expect(row.openingsJson, '[]');
      expect(row.queuedAt, null);

      await after.close();
    });

    test('running the upgrade twice does not throw', () async {
      final first = await open();
      await first.close();

      final second = await open();
      expect(await userVersion(second), 16);
      await second.close();
    });
  });

  group(
    'v14 → v15 — a per_sqft line can price from a pre-known area (property library)',
    () {
      test('an existing measured line keeps its width, untouched', () async {
        // The whole point of `alterTable` over a plain `addColumn`: it
        // recreates the table, and a bug there could silently drop or
        // corrupt every row already on the handset rather than merely
        // fail to add a column.
        final before = await open();
        await seedOrderLine(before);
        await windBackTo(before, 14);
        await before.close();

        final after = await open();
        expect(await userVersion(after), 16);

        final line = await (after.select(
          after.orderLines,
        )..where((l) => l.id.equals('ol-1'))).getSingle();
        expect(
          line.estWidthTmm,
          36576,
          reason:
              'a real width on a line already on the handset must survive '
              'the table recreate',
        );
        expect(
          line.lineTotalSen,
          96000,
          reason: 'the money on a line in the field is untouched',
        );
        expect(line.directAreaSqft, null);

        await after.close();
      });

      test(
        'a room-sourced line can now be written with no width at all',
        () async {
          // The point of widening to nullable in the first place. A migration
          // that recreated the table but left `width_tmm` NOT NULL would pass
          // every check above and still throw the moment a real room-sourced
          // line tried to insert.
          final before = await open();
          await seedOrderLine(before);
          await windBackTo(before, 14);
          await before.close();

          final after = await open();

          await after
              .into(after.quoteLines)
              .insert(
                QuoteLinesCompanion.insert(
                  id: 'ql-room',
                  quoteId: 'q-1',
                  sortOrder: 0,
                  room: 'Living',
                  variant: 'spc_4mm_1mm',
                  layer: 'single',
                  widthTmm: const Value(null),
                  rawWidth: '',
                  rawHeight: '',
                  directAreaSqft: const Value('700/3'),
                  createdAt: DateTime(2026, 9, 13, 9),
                ),
              );

          final quoteLine = await (after.select(
            after.quoteLines,
          )..where((l) => l.id.equals('ql-room'))).getSingle();
          expect(quoteLine.widthTmm, null);
          expect(quoteLine.directAreaSqft, '700/3');

          await (after.update(
            after.orderLines,
          )..where((l) => l.id.equals('ol-1'))).write(
            const OrderLinesCompanion(
              estWidthTmm: Value(null),
              directAreaSqft: Value('250'),
            ),
          );
          final orderLine = await (after.select(
            after.orderLines,
          )..where((l) => l.id.equals('ol-1'))).getSingle();
          expect(orderLine.estWidthTmm, null);
          expect(orderLine.directAreaSqft, '250');

          await after.close();
        },
      );

      test('running the upgrade twice does not throw', () async {
        final first = await open();
        await first.close();

        final second = await open();
        expect(await userVersion(second), 16);
        await second.close();
      });
    },
  );

  group(
    'v15 → v16 — where a visit is, and when the house is ready (§13 C10)',
    () {
      test('the order already on the handset survives it', () async {
        final before = await open();
        await seedOrderLine(before);
        await windBackTo(before, 15);
        await before.close();

        final after = await open();
        expect(await userVersion(after), 16);
        final order = await (after.select(
          after.orders,
        )..where((o) => o.id.equals('o-1'))).getSingle();
        expect(order.estimateTotalSen, 96000);
        expect(order.sitePostcode, null);
        expect(order.siteReadyFrom, null);
        await after.close();
      });

      test('the new columns are writable, on both tables', () async {
        final before = await open();
        await seedOrderLine(before);
        await windBackTo(before, 15);
        await before.close();

        final after = await open();
        await (after.update(
          after.orders,
        )..where((o) => o.id.equals('o-1'))).write(
          OrdersCompanion(
            siteAddress: const Value('3 Jalan Bunga, Taman Bunga'),
            sitePostcode: const Value('75450'),
            siteReadyFrom: Value(DateTime(2026, 11, 1)),
            siteCapturedAt: Value(DateTime.utc(2026, 9, 1, 3)),
          ),
        );
        await (after.update(
          after.quotes,
        )..where((q) => q.id.equals('q-1'))).write(
          QuotesCompanion(
            siteAddress: const Value('3 Jalan Bunga'),
            sitePostcode: const Value('75450'),
            siteReadyFrom: Value(DateTime(2026, 11, 1)),
          ),
        );

        final order = await (after.select(
          after.orders,
        )..where((o) => o.id.equals('o-1'))).getSingle();
        expect(order.sitePostcode, '75450');
        expect(order.siteReadyFrom, DateTime(2026, 11, 1));
        final quote = await (after.select(
          after.quotes,
        )..where((q) => q.id.equals('q-1'))).getSingle();
        expect(quote.siteAddress, '3 Jalan Bunga');
        await after.close();
      });

      test('running the upgrade twice does not throw', () async {
        // `addColumn` is not idempotent: a loosened guard fails with a
        // duplicate column name, on launch, on a handset that already migrated.
        final first = await open();
        await first.close();
        final second = await open();
        expect(await userVersion(second), 16);
        await second.close();
      });
    },
  );
}

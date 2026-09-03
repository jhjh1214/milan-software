/// Moving an order along, on a real database. SPEC.md §6.3.
///
/// Which transitions are legal is decided in `pricing/order_status.dart` and
/// tested against the shared fixtures. What is checked here is the part only a
/// database can get wrong: that the status and its event move together, that a
/// refusal writes nothing at all, and that the guards are fed the line state
/// actually stored rather than what the caller believes.
///
/// `order_events` is append-only (CLAUDE.md), so a status that moved without
/// its event is a job whose history has a hole exactly where somebody will
/// later look — and nothing in the app would ever notice.
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/length.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/core/rational.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/order_repository.dart';
import 'package:milan_quote/pricing/conversion.dart';
import 'package:milan_quote/pricing/order_status.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

void main() {
  late AppDatabase db;
  late OrderRepository repo;

  final confirmedAt = DateTime(2026, 8, 29, 14, 0);
  var clock = confirmedAt;
  DateTime tick() => clock = clock.add(const Duration(minutes: 5));

  OrderLineDraft line(
    String id, {
    bool materialDeferred = true,
    String? materialKey,
  }) => OrderLineDraft(
    id: id,
    quoteLineId: 'ql-$id',
    sortOrder: 0,
    room: 'Living room',
    variant: 'night_curtain_sfold',
    materialKey: materialKey,
    layer: 'night',
    estWidth: Length.of(const Rational.fromInt(12), LengthUnit.foot),
    estHeight: Length.of(const Rational.fromInt(9), LengthUnit.foot),
    quantity: 1,
    appliedRuleId: 'rule-1',
    appliedRateCardVersion: 1,
    appliedDiscountPct: Rational.zero,
    standardRateSen: 8000,
    rateSen: 8000,
    billedQty: '12',
    billedUnit: 'ft',
    lineTotal: const Money.sen(96000),
    materialDeferred: materialDeferred,
  );

  Future<String> confirm({List<OrderLineDraft>? lines}) async {
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q1',
            channel: const Value('fair'),
            rateCardVersion: 1,
            createdAt: confirmedAt,
            updatedAt: confirmedAt,
          ),
        );
    await repo.store(
      OrderDraft(
        id: 'o1',
        quoteId: 'q1',
        channel: Channel.fair,
        pinnedRateCardVersion: 1,
        estimateTotal: const Money.sen(96000),
        depositPaid: const Money.sen(30000),
        lines: lines ?? [line('l1')],
        confirmedAt: confirmedAt,
      ),
      byUserId: 'u-boss',
    );
    return 'o1';
  }

  Future<OrderRow> read(String id) =>
      (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();

  Future<void> measureEverything(String orderId) =>
      (db.update(db.orderLines)..where((l) => l.orderId.equals(orderId))).write(
        const OrderLinesCompanion(isSiteMeasured: Value(true)),
      );

  Future<void> chooseMaterials(String orderId) =>
      (db.update(db.orderLines)..where((l) => l.orderId.equals(orderId))).write(
        const OrderLinesCompanion(materialKey: Value('tbl')),
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = OrderRepository(db);
    clock = confirmedAt;
  });

  tearDown(() => db.close());

  group('a confirmed order', () {
    test('starts at confirmed with an event to match', () async {
      final id = await confirm();
      expect((await read(id)).status, 'confirmed');

      final history = await repo.historyOf(id);
      expect(history.single.event, 'confirmed');
    });

    test('moves along the pipeline, one event per step', () async {
      final id = await confirm();

      final booked = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
        byUserId: 'u-boss',
      );
      expect(booked.isAllowed, isTrue);
      expect((await read(id)).status, 'measurement_booked');

      await measureEverything(id);
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
      );
      expect((await read(id)).status, 'measured');

      final history = await repo.historyOf(id);
      expect(history.map((e) => e.event), [
        'confirmed',
        'measurement_booked',
        'measured',
      ]);
    });

    test('records who moved it', () async {
      // The history has to name a person. An event with nobody on it is the
      // one somebody will be asked about a year later.
      final id = await confirm();
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
        byUserId: 'u-ah-lian',
      );
      final history = await repo.historyOf(id);
      expect(history.last.byUserId, 'u-ah-lian');
    });
  });

  group('a refusal', () {
    test('leaves the status alone and writes no event', () async {
      final id = await confirm();

      final result = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.inProduction,
        at: tick(),
      );

      expect(result.isAllowed, isFalse);
      expect(result.refusedBecause, StatusRefusal.notATransition);
      expect((await read(id)).status, 'confirmed');
      expect(
        (await repo.historyOf(id)).map((e) => e.event),
        ['confirmed'],
        reason: 'a refused move must not leave a footprint in the history',
      );
    });

    test('reads the line state out of the database, not the caller', () async {
      // The guard is only worth having if it looks at the stored rows. Asking
      // the caller whether the order is measured is asking the button that
      // wants to move it.
      final id = await confirm();
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
      );

      final tooEarly = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
      );
      expect(tooEarly.refusedBecause, StatusRefusal.linesNotMeasured);

      await measureEverything(id);
      final now = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
      );
      expect(now.isAllowed, isTrue);
    });

    test(
      'a deferred material blocks material_selected until one is set',
      () async {
        final id = await confirm();
        await repo.advanceStatus(
          orderId: id,
          to: OrderStatus.measurementBooked,
          at: tick(),
        );
        await measureEverything(id);
        await repo.advanceStatus(
          orderId: id,
          to: OrderStatus.measured,
          at: tick(),
        );

        final stillDeferred = await repo.advanceStatus(
          orderId: id,
          to: OrderStatus.materialSelected,
          at: tick(),
        );
        expect(stillDeferred.refusedBecause, StatusRefusal.materialNotChosen);

        await chooseMaterials(id);
        expect(
          (await repo.advanceStatus(
            orderId: id,
            to: OrderStatus.materialSelected,
            at: tick(),
          )).isAllowed,
          isTrue,
        );
      },
    );

    test('a line whose material was never deferred does not block', () async {
      // §13 B7 defers material on seven variants, not on everything. A line
      // that never deferred has nothing to choose, and must not hold the order.
      final id = await confirm(lines: [line('l1', materialDeferred: false)]);
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
      );
      await measureEverything(id);
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
      );
      expect(
        (await repo.advanceStatus(
          orderId: id,
          to: OrderStatus.materialSelected,
          at: tick(),
        )).isAllowed,
        isTrue,
      );
    });
  });

  group('cancelling', () {
    test('stores the reason as given, for §13 B3 to be settled from', () async {
      final id = await confirm();
      final result = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        byUserId: 'u-boss',
        reason: 'customer bought elsewhere',
      );

      expect(result.isAllowed, isTrue);
      expect((await read(id)).status, 'cancelled');

      final last = (await repo.historyOf(id)).last;
      expect(last.event, 'cancelled');
      expect(last.note, 'customer bought elsewhere');
      expect(last.byUserId, 'u-boss');
    });

    test('without a reason nothing is written', () async {
      final id = await confirm();
      final result = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        reason: '  ',
      );

      expect(result.refusedBecause, StatusRefusal.noReason);
      expect((await read(id)).status, 'confirmed');
      expect((await repo.historyOf(id)).length, 1);
    });

    test('a cancelled order stops moving', () async {
      final id = await confirm();
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        reason: 'customer bought elsewhere',
      );

      for (final to in OrderStatus.values) {
        final result = await repo.advanceStatus(
          orderId: id,
          to: to,
          at: tick(),
          reason: 'a perfectly good reason',
        );
        expect(result.isAllowed, isFalse, reason: 'cancelled -> $to');
      }
      expect((await repo.historyOf(id)).length, 2);
    });

    test('the deposit is left exactly where it was', () async {
      // §13 B3 is unanswered: forfeit, partial or credit. Until it is answered
      // the honest thing is to touch none of it — a zeroed deposit would be a
      // decision nobody made, written into the ledger.
      final id = await confirm();
      final before = (await read(id)).depositPaidSen;
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        reason: 'customer bought elsewhere',
      );
      expect((await read(id)).depositPaidSen, before);
      expect(before, 30000);
    });
  });

  test('the estimate never moves, whatever the status does', () async {
    // It is the record of what was quoted, and what the variance report
    // compares the final against.
    final id = await confirm();
    final estimate = (await read(id)).estimateTotalSen;

    await repo.advanceStatus(
      orderId: id,
      to: OrderStatus.measurementBooked,
      at: tick(),
    );
    await measureEverything(id);
    await repo.advanceStatus(orderId: id, to: OrderStatus.measured, at: tick());

    expect((await read(id)).estimateTotalSen, estimate);
  });
}

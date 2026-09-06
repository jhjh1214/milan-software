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
import 'package:milan_quote/pricing/einvoice_threshold.dart';
import 'package:milan_quote/pricing/order_status.dart';
import 'package:milan_quote/pricing/price_override.dart';
import 'package:milan_quote/pricing/rate_lock.dart';

/// The RM10,000 figures the pipeline is handed. SPEC.md §10.3: they live on
/// the rate card, so a caller passes them rather than the repository reading
/// one.
///
/// These are the real values, not a disabled stand-in. Every order in this
/// file is a few hundred ringgit, so the guard never fires -- and if one ever
/// grows past RM10,000 the test should notice.
const _thresholds = ThresholdConfig(
  threshold: Money.sen(1000000),
  prompt: Money.sen(800000),
);

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
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
        byUserId: 'u-boss',
      );
      expect(booked.isAllowed, isTrue);
      expect((await read(id)).status, 'measurement_booked');

      await measureEverything(id);
      await repo.advanceStatus(
        thresholds: _thresholds,
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
        thresholds: _thresholds,
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
        thresholds: _thresholds,
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
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
      );

      final tooEarly = await repo.advanceStatus(
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
      );
      expect(tooEarly.refusedBecause, StatusRefusal.linesNotMeasured);

      await measureEverything(id);
      final now = await repo.advanceStatus(
        thresholds: _thresholds,
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
          thresholds: _thresholds,
          orderId: id,
          to: OrderStatus.measurementBooked,
          at: tick(),
        );
        await measureEverything(id);
        await repo.advanceStatus(
          thresholds: _thresholds,
          orderId: id,
          to: OrderStatus.measured,
          at: tick(),
        );

        final stillDeferred = await repo.advanceStatus(
          thresholds: _thresholds,
          orderId: id,
          to: OrderStatus.materialSelected,
          at: tick(),
        );
        expect(stillDeferred.refusedBecause, StatusRefusal.materialNotChosen);

        await chooseMaterials(id);
        expect(
          (await repo.advanceStatus(
            thresholds: _thresholds,
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
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
      );
      await measureEverything(id);
      await repo.advanceStatus(
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
      );
      expect(
        (await repo.advanceStatus(
          thresholds: _thresholds,
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
        thresholds: _thresholds,
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
        thresholds: _thresholds,
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
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        reason: 'customer bought elsewhere',
      );

      for (final to in OrderStatus.values) {
        final result = await repo.advanceStatus(
          thresholds: _thresholds,
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
        thresholds: _thresholds,
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
      thresholds: _thresholds,
      orderId: id,
      to: OrderStatus.measurementBooked,
      at: tick(),
    );
    await measureEverything(id);
    await repo.advanceStatus(
      thresholds: _thresholds,
      orderId: id,
      to: OrderStatus.measured,
      at: tick(),
    );

    expect((await read(id)).estimateTotalSen, estimate);
  });

  group('overriding a line price', () {
    Future<String> lineOf(String orderId) async =>
        (await repo.linesOf(orderId)).first.id;

    test('moves the total, marks the line, and writes the audit row', () async {
      final id = await confirm();
      final lineId = await lineOf(id);

      final result = await repo.overrideLineTotal(
        orderLineId: lineId,
        newTotal: const Money.sen(90000),
        reason: 'matched a competitor quote',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
        deviceId: 'handset-3',
      );
      expect(result.isApplied, isTrue);

      final line = (await repo.linesOf(id)).single;
      expect(line.lineTotalSen, 90000);
      expect(line.isOverridden, isTrue);

      final audit = (await repo.overridesOn(id)).single;
      expect(audit.beforeSen, 96000);
      expect(audit.afterSen, 90000);
      expect(audit.reason, 'matched a competitor quote');
      expect(audit.adminUserId, 'u-boss');
      expect(audit.deviceId, 'handset-3');
    });

    test('shows up in the order history too', () async {
      // Two readers, two places. The audit table is the weekly review; the
      // event log is what somebody scrolls when one customer asks.
      final id = await confirm();
      await repo.overrideLineTotal(
        orderLineId: await lineOf(id),
        newTotal: const Money.sen(90000),
        reason: 'matched a competitor quote',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
      );

      final last = (await repo.historyOf(id)).last;
      expect(last.event, 'price_overridden');
      expect(last.note, contains('RM 960.00'));
      expect(last.note, contains('RM 900.00'));
      expect(last.note, contains('matched a competitor quote'));
      expect(last.byUserId, 'u-boss');
    });

    test('a refusal changes nothing at all', () async {
      // The price and the audit row are one write or neither. A price that
      // moved without its row is the single case the weekly review cannot
      // show, which is exactly the case somebody would want hidden.
      final id = await confirm();
      final lineId = await lineOf(id);

      for (final attempt in [
        () => repo.overrideLineTotal(
          orderLineId: lineId,
          newTotal: const Money.sen(90000),
          reason: 'matched a competitor quote',
          adminUserId: 'u-ah-lian',
          isAdmin: false,
          at: tick(),
        ),
        () => repo.overrideLineTotal(
          orderLineId: lineId,
          newTotal: const Money.sen(90000),
          reason: 'no',
          adminUserId: 'u-boss',
          isAdmin: true,
          at: tick(),
        ),
        () => repo.overrideLineTotal(
          orderLineId: lineId,
          newTotal: const Money.sen(-1),
          reason: 'a perfectly good reason',
          adminUserId: 'u-boss',
          isAdmin: true,
          at: tick(),
        ),
      ]) {
        expect((await attempt()).isApplied, isFalse);
      }

      final line = (await repo.linesOf(id)).single;
      expect(line.lineTotalSen, 96000);
      expect(line.isOverridden, isFalse);
      expect(await repo.overridesOn(id), isEmpty);
      expect((await repo.historyOf(id)).length, 1);
    });

    test('a cancelled order cannot be repriced', () async {
      final id = await confirm();
      await repo.advanceStatus(
        thresholds: _thresholds,
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        reason: 'customer bought elsewhere',
      );

      final result = await repo.overrideLineTotal(
        orderLineId: await lineOf(id),
        newTotal: const Money.sen(90000),
        reason: 'matched a competitor quote',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
      );
      expect(result.refusedBecause, OverrideRefusal.orderFinished);
      expect((await repo.linesOf(id)).single.lineTotalSen, 96000);
    });

    test('two overrides on one line both survive', () async {
      // Append-only. The second must not overwrite the first, or the review
      // sees one move where there were two and the intermediate number — the
      // one somebody may have quoted aloud — disappears.
      final id = await confirm();
      final lineId = await lineOf(id);

      await repo.overrideLineTotal(
        orderLineId: lineId,
        newTotal: const Money.sen(90000),
        reason: 'matched a competitor quote',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
      );
      await repo.overrideLineTotal(
        orderLineId: lineId,
        newTotal: const Money.sen(85000),
        reason: 'customer pushed again',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
      );

      final audit = await repo.overridesOn(id);
      expect(audit.map((o) => (o.beforeSen, o.afterSen)), [
        (96000, 90000),
        (90000, 85000),
      ]);
      expect((await repo.linesOf(id)).single.lineTotalSen, 85000);
    });

    test('the marker is never cleared by a later override', () async {
      // A line moved back to its original total is still a line somebody moved
      // by hand, and the printed quote has to keep saying so.
      final id = await confirm();
      final lineId = await lineOf(id);

      await repo.overrideLineTotal(
        orderLineId: lineId,
        newTotal: const Money.sen(90000),
        reason: 'matched a competitor quote',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
      );
      await repo.overrideLineTotal(
        orderLineId: lineId,
        newTotal: const Money.sen(96000),
        reason: 'competitor quote was withdrawn',
        adminUserId: 'u-boss',
        isAdmin: true,
        at: tick(),
      );

      final line = (await repo.linesOf(id)).single;
      expect(line.lineTotalSen, 96000);
      expect(line.isOverridden, isTrue);
      expect((await repo.overridesOn(id)).length, 2);
    });
  });

  group('the overrides this week screen', () {
    test('reads a window, newest first, and excludes its far edge', () async {
      // §6.5: "without it the log is never read and the control does not
      // exist." An off-by-one at either edge either double counts a row in two
      // weeks or drops it from both.
      final id = await confirm();
      final lineId = (await repo.linesOf(id)).first.id;

      final monday = DateTime(2026, 8, 24);
      final sunday = DateTime(2026, 8, 30);
      final nextMonday = DateTime(2026, 8, 31);

      var total = 96000;
      for (final at in [
        monday.subtract(const Duration(seconds: 1)),
        monday,
        DateTime(2026, 8, 27, 11),
        sunday,
        nextMonday,
      ]) {
        total -= 100;
        await repo.overrideLineTotal(
          orderLineId: lineId,
          newTotal: Money.sen(total),
          reason: 'a perfectly good reason',
          adminUserId: 'u-boss',
          isAdmin: true,
          at: at,
        );
      }

      final week = await repo.overridesBetween(from: monday, to: nextMonday);
      expect(week.length, 3);
      expect(
        week.map((o) => o.at),
        [sunday, DateTime(2026, 8, 27, 11), monday],
        reason: 'newest first, the Monday included and the next Monday not',
      );
    });

    test('is empty rather than null when nobody overrode anything', () async {
      expect(
        await repo.overridesBetween(
          from: DateTime(2026, 8, 24),
          to: DateTime(2026, 8, 31),
        ),
        isEmpty,
      );
    });
  });

  group('buyer details and the RM10,000 rule', () {
    /// An order big enough to be over the legal line once measured.
    Future<String> bigOrder() async {
      final id = await confirm();
      await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        const OrdersCompanion(
          estimateTotalSen: Value(1450000),
          finalTotalSen: Value(1450000),
        ),
      );
      return id;
    }

    Future<void> reachMeasured(String id) async {
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measurementBooked,
        at: tick(),
        thresholds: _thresholds,
      );
      await measureEverything(id);
      await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.measured,
        at: tick(),
        thresholds: _thresholds,
      );
    }

    Future<void> fillIn(String id) => repo.recordBuyerDetails(
      orderId: id,
      name: 'Ah Lian',
      idType: 'nric',
      idNumber: '880101105566',
      addressLine1: '12 Jalan Merdeka',
      city: 'Melaka',
      state: 'Melaka',
      postcode: '75000',
    );

    test('a big order stops after measured until details exist', () async {
      // §10.4, and the whole point of the phase's third criterion. The block
      // is in the state machine, so no screen can be the thing that forgot.
      final id = await bigOrder();
      await reachMeasured(id);
      await chooseMaterials(id);

      final refused = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(refused.isAllowed, isFalse);
      expect(refused.refusedBecause, StatusRefusal.buyerDetailsRequired);
      expect(
        (await read(id)).status,
        'measured',
        reason: 'a refusal writes nothing at all',
      );
    });

    test('and moves the moment they do', () async {
      final id = await bigOrder();
      await reachMeasured(id);
      await chooseMaterials(id);
      await fillIn(id);

      final allowed = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(allowed.isAllowed, isTrue);
      expect((await read(id)).status, 'material_selected');
    });

    test('half the details are not details', () async {
      // The identifier is the piece somebody skips, because it is the one the
      // customer has to go and find.
      final id = await bigOrder();
      await reachMeasured(id);
      await chooseMaterials(id);
      await repo.recordBuyerDetails(
        orderId: id,
        name: 'Ah Lian',
        addressLine1: '12 Jalan Merdeka',
        city: 'Melaka',
        state: 'Melaka',
        postcode: '75000',
      );

      final refused = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(refused.refusedBecause, StatusRefusal.buyerDetailsRequired);
    });

    test('a big order can still be cancelled', () async {
      // Cancelling has nothing to do with invoicing. Refusing it would leave
      // the order trapped with no way out.
      final id = await bigOrder();
      await reachMeasured(id);

      final cancelled = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.cancelled,
        at: tick(),
        reason: 'customer bought elsewhere',
        thresholds: _thresholds,
      );

      expect(cancelled.isAllowed, isTrue);
      expect((await read(id)).status, 'cancelled');
    });

    test('a small order is never asked', () async {
      // Most walk-ins are General Public (§10.3). Asking everybody for an IC
      // number is the friction that makes staff stop asking at all.
      final id = await confirm();
      await reachMeasured(id);
      await chooseMaterials(id);

      final allowed = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(allowed.isAllowed, isTrue);
    });

    test('an unmeasured order is judged on its estimate', () async {
      // §10.4 checks twice. Before the tape there is no final, and using
      // nothing would let a RM14,500 estimate walk past the guard.
      final id = await confirm();
      await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        const OrdersCompanion(estimateTotalSen: Value(1450000)),
      );
      await reachMeasured(id);
      await chooseMaterials(id);

      final refused = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(refused.refusedBecause, StatusRefusal.buyerDetailsRequired);
    });

    test('an estimate that measured back under is let through', () async {
      // The commoner direction: the quote rounds every quantity up, so a final
      // can land under a line the estimate crossed. Holding the order for
      // details it no longer needs would be the rule inventing work.
      final id = await confirm();
      await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        const OrdersCompanion(
          estimateTotalSen: Value(1450000),
          finalTotalSen: Value(980000),
        ),
      );
      await reachMeasured(id);
      await chooseMaterials(id);

      final allowed = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(allowed.isAllowed, isTrue);
    });

    test('an asked-for e-invoice blocks a small order too', () async {
      // §10.3: required whenever the customer asks, at any value.
      final id = await confirm();
      await reachMeasured(id);
      await chooseMaterials(id);
      await repo.recordBuyerDetails(orderId: id, einvoiceRequested: true);

      final refused = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: _thresholds,
      );

      expect(refused.refusedBecause, StatusRefusal.buyerDetailsRequired);
    });

    test('the thresholds come from the caller, not from this file', () async {
      // §10.3: they live on the rate card because they will change. Handing
      // in a higher line lets a RM14,500 order through, which is what a
      // published change has to be able to do.
      final id = await bigOrder();
      await reachMeasured(id);
      await chooseMaterials(id);

      final allowed = await repo.advanceStatus(
        orderId: id,
        to: OrderStatus.materialSelected,
        at: tick(),
        thresholds: const ThresholdConfig(
          threshold: Money.sen(2000000),
          prompt: Money.sen(1800000),
        ),
      );

      expect(allowed.isAllowed, isTrue);
    });
  });

  group('recording buyer details', () {
    test('stores what was given, trimmed', () async {
      final id = await confirm();
      await repo.recordBuyerDetails(
        orderId: id,
        name: '  Ah Lian  ',
        tin: 'C12345678901',
        addressLine1: ' 12 Jalan Merdeka ',
        city: 'Melaka',
        state: 'Melaka',
        postcode: '75000',
      );

      final order = await read(id);
      expect(order.customerName, 'Ah Lian');
      expect(order.buyerTin, 'C12345678901');
      expect(order.buyerAddressLine1, '12 Jalan Merdeka');
    });

    test('a field somebody tabbed through is stored as absent', () async {
      // Not as a space that satisfies a legal requirement it does not meet.
      final id = await confirm();
      await repo.recordBuyerDetails(orderId: id, tin: '   ');

      expect((await read(id)).buyerTin, isNull);
    });

    test('saving one section does not blank another', () async {
      // A screen with two panels must not be a screen where filling the second
      // erases the first.
      final id = await confirm();
      await repo.recordBuyerDetails(orderId: id, tin: 'C12345678901');
      await repo.recordBuyerDetails(
        orderId: id,
        addressLine1: '12 Jalan Merdeka',
        city: 'Melaka',
        state: 'Melaka',
        postcode: '75000',
      );

      final order = await read(id);
      expect(order.buyerTin, 'C12345678901');
      expect(order.buyerCity, 'Melaka');
    });

    test('reads back as the rule expects them', () async {
      final id = await confirm();
      await repo.recordBuyerDetails(
        orderId: id,
        name: 'Ah Lian',
        idType: 'nric',
        idNumber: '880101105566',
        addressLine1: '12 Jalan Merdeka',
        city: 'Melaka',
        state: 'Melaka',
        postcode: '75000',
      );

      final buyer = OrderRepository.buyerDetailsOf(await read(id));
      expect(buyerDetailsComplete(buyer), isTrue);
      expect(missingBuyerDetails(buyer), isEmpty);
    });

    test('an order the fair never named is missing its name too', () async {
      // A fair takes deposits fast and a quote can carry a phone and no name.
      // An invoice cannot be issued from that, and the name has to come off
      // the order rather than be assumed present.
      final id = await confirm();
      final buyer = OrderRepository.buyerDetailsOf(await read(id));

      expect(buyerDetailsComplete(buyer), isFalse);
      expect(
        missingBuyerDetails(buyer).map((m) => m.wire).toList(),
        <String>['name', 'identifier', 'address'],
        reason: 'everything outstanding, exactly, in order',
      );
    });

    test(
      'a name recorded at the fair is the name the invoice starts from',
      () async {
        final id = await confirm();
        await repo.recordBuyerDetails(orderId: id, name: 'Ah Lian');

        final buyer = OrderRepository.buyerDetailsOf(await read(id));
        expect(buyer.name, 'Ah Lian');
        expect(
          missingBuyerDetails(buyer).map((m) => m.wire).toList(),
          <String>['identifier', 'address'],
          reason: 'the name stops being outstanding once it is there',
        );
      },
    );
  });
}

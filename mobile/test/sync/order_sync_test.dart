/// Pushing a confirmed order, and the number that comes back. SPEC.md §6.3.
///
/// A deposit already changed hands before any of this ran, so nothing about the
/// sale waits on the network — only the order number does, and until it arrives
/// the screen says "pending sync" rather than showing one the device invented.
///
/// The failure being designed against is the ordinary one at a fair: the
/// connection drops and the device cannot tell a lost request from a lost
/// response. Sending again has to cost nothing.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/order_repository.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/pricing/einvoice_threshold.dart';
import 'package:milan_quote/pricing/order_status.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/order_payload.dart';
import 'package:milan_quote/sync/outbox.dart';

import 'fake_server.dart';

const credentials = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Boss', role: 'admin', language: 'zh'),
);

final at = DateTime.utc(2026, 8, 29, 14);

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
  late OrderRepository orders;
  late FakeServer server;
  late Outboxer outboxer;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    orders = OrderRepository(db);
    server = FakeServer();
    outboxer = Outboxer(
      db: db,
      api: ApiClient(
        baseUrl: Uri.parse('https://example.test'),
        client: server.client,
        timeout: const Duration(milliseconds: 200),
      ),
      clock: () => at,
    );
  });

  tearDown(() => db.close());

  const orderId = '11111111-1111-4111-8111-111111111111';
  const lineId = '22222222-2222-4222-8222-222222222222';

  Future<void> seed() async {
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q1',
            rateCardVersion: 1,
            channel: const Value('fair'),
            createdAt: at,
            updatedAt: at,
          ),
        );
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: orderId,
            quoteId: 'q1',
            channel: 'fair',
            pinnedRateCardVersion: 1,
            estimateTotalSen: 96000,
            depositPaidSen: const Value(30000),
            confirmedAt: at,
          ),
        );
    await db
        .into(db.orderLines)
        .insert(
          OrderLinesCompanion.insert(
            id: lineId,
            orderId: orderId,
            quoteLineId: 'ql1',
            sortOrder: 0,
            room: 'Living room',
            variant: 'night_curtain_sfold',
            layer: 'night',
            estWidthTmm: const Value(36576),
            estHeightTmm: const Value(27432),
            appliedRuleId: 'rule-1',
            appliedRateCardVersion: 1,
            standardRateSen: 8000,
            rateSen: 8000,
            billedQty: '12',
            billedUnit: 'ft',
            lineTotalSen: 96000,
            materialDeferred: const Value(true),
          ),
        );
    await db
        .into(db.orderEvents)
        .insert(
          OrderEventsCompanion.insert(
            id: 'ev-confirmed',
            orderId: orderId,
            event: 'confirmed',
            at: at,
          ),
        );
  }

  Future<void> queueOrder() async {
    await outboxer.enqueueOrder(
      orderId,
      orderPayload(
        order: (await orders.forQuote('q1'))!,
        lines: await orders.linesOf(orderId),
        events: await orders.historyOf(orderId),
        overrides: await orders.overridesOn(orderId),
        deviceId: 'handset-3',
      ),
    );
  }

  Future<OrderRow> read() =>
      (db.select(db.orders)..where((o) => o.id.equals(orderId))).getSingle();

  group('pushing the order', () {
    test('the number comes back and is written onto the order', () async {
      await seed();
      expect(
        (await read()).orderNo,
        isNull,
        reason: 'until the server answers there is no number to show',
      );

      await queueOrder();
      final report = await outboxer.drain(credentials);

      expect(report.sent, [orderId]);
      expect((await read()).orderNo, 'MLK-2608-0001');
      expect((await read()).syncedAt, at);
      expect(await db.pendingOutbox(), isEmpty);
    });

    test('the device never sends a number of its own', () async {
      // There is no field for it. A device that could set one would collide
      // with every other device offline at the same fair, on a document the
      // customer takes away.
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      final body =
          jsonDecode(utf8.decode(server.lastOrderBody!))
              as Map<String, dynamic>;
      expect(body.containsKey('order_no'), isFalse);
      expect(body.containsKey('confirmed_by_user_id'), isFalse);
    });

    test('the lines and the history go up with it', () async {
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      final body =
          jsonDecode(utf8.decode(server.lastOrderBody!))
              as Map<String, dynamic>;
      final lines = body['lines'] as List<dynamic>;
      expect(lines.length, 1);
      expect((lines.single as Map)['est_width_tmm'], 36576);
      expect(
        (lines.single as Map)['applied_rate_card_version'],
        1,
        reason: 'the snapshot is what keeps the number explainable later',
      );
      expect((body['events'] as List).length, 1);
    });

    test(
      'a line typed by hand goes up as manual, with no source ids',
      () async {
        // SPEC.md Phase 8. `seed()` writes a line with no source columns set
        // -- the truth for every order before the library existed.
        await seed();
        await queueOrder();
        await outboxer.drain(credentials);

        final body =
            jsonDecode(utf8.decode(server.lastOrderBody!))
                as Map<String, dynamic>;
        final line = (body['lines'] as List).single as Map<String, dynamic>;
        expect(line['measurement_source'], 'manual');
        expect(line['source_project_id'], null);
        expect(line['source_unit_type_id'], null);
        expect(line['source_version'], null);
      },
    );

    test('a line from a saved plan keeps its trail up to the server', () async {
      // SPEC.md Phase 8: the whole point of the provenance columns is that
      // this survives the trip, not just the local row.
      await seed();
      await (db.update(db.orderLines)..where((l) => l.id.equals(lineId))).write(
        const OrderLinesCompanion(
          measurementSource: Value('project_library'),
          sourceProjectId: Value('p-1'),
          sourceUnitTypeId: Value('ut-1'),
          sourceVersion: Value(2),
        ),
      );
      await queueOrder();
      await outboxer.drain(credentials);

      final body =
          jsonDecode(utf8.decode(server.lastOrderBody!))
              as Map<String, dynamic>;
      final line = (body['lines'] as List).single as Map<String, dynamic>;
      expect(line['measurement_source'], 'project_library');
      expect(line['source_project_id'], 'p-1');
      expect(line['source_unit_type_id'], 'ut-1');
      expect(line['source_version'], 2);
    });

    test('timestamps go up in UTC', () async {
      // An order confirmed at 11pm on the last night of a fair must not become
      // the next month in transit — the number is issued from this date.
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      final body =
          jsonDecode(utf8.decode(server.lastOrderBody!))
              as Map<String, dynamic>;
      expect(body['confirmed_at'], endsWith('Z'));
      expect(DateTime.parse(body['confirmed_at'] as String), at);
    });

    test('a retry gets the same number and creates nothing new', () async {
      // The ordinary failure at a fair: the server committed, the response
      // never arrived, and the device sends again.
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);
      final first = (await read()).orderNo;

      await queueOrder();
      await outboxer.drain(credentials);

      expect((await read()).orderNo, first);
      expect(server.orderNumbers.length, 1);
    });

    test('an order queued offline survives until there is signal', () async {
      await seed();
      await queueOrder();

      server.offline = true;
      final blocked = await outboxer.drain(credentials);
      expect(blocked.failure, SyncFailure.offline);
      expect((await read()).orderNo, isNull);
      expect(await db.pendingOutbox(), hasLength(1));

      server.offline = false;
      await outboxer.drain(credentials);
      expect((await read()).orderNo, 'MLK-2608-0001');
    });

    test('a partly-accepted order is reported, not swallowed', () async {
      // The order landed and the money is safe, but the server would not take
      // all of it. A refused override means a price moved on one handset with
      // no audit row anywhere else, which is exactly what §6.5 exists to stop.
      await seed();
      server.refuseOverrides = {'ov-1': 'no_change'};
      await queueOrder();

      final report = await outboxer.drain(credentials);
      expect(report.sent, [orderId]);
      expect(report.disagreed, [orderId]);
      expect(
        (await read()).orderNo,
        'MLK-2608-0001',
        reason: 'the order still landed — refusing it would lose the sale',
      );
    });
  });

  group('pushing a step along the pipeline', () {
    Future<String> advance(OrderStatus to, {String? reason}) async {
      final before = await orders.historyOf(orderId);
      await orders.advanceStatus(
        thresholds: _thresholds,
        orderId: orderId,
        to: to,
        at: at,
        reason: reason,
      );
      final after = await orders.historyOf(orderId);
      final event = after.firstWhere((e) => !before.any((b) => b.id == e.id));

      await outboxer.enqueueStatusChange(
        event.id,
        statusChangePayload(orderId: orderId, event: event),
      );
      return event.id;
    }

    test('a move is sent and stamped on its own event', () async {
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      final eventId = await advance(OrderStatus.measurementBooked);
      final report = await outboxer.drain(credentials);

      expect(report.sent, [eventId]);
      expect(server.orderStatus[orderId], 'measurement_booked');

      final event = (await orders.historyOf(
        orderId,
      )).firstWhere((e) => e.id == eventId);
      expect(event.syncedAt, at);
    });

    test('each step is its own row, keyed on the event', () async {
      // Keying on the order would have the second step overwrite the first
      // while it was still queued, and the history would lose a step that
      // really happened.
      await seed();
      await queueOrder();

      final booked = await advance(OrderStatus.measurementBooked);
      await (db.update(db.orderLines)..where((l) => l.orderId.equals(orderId)))
          .write(const OrderLinesCompanion(isSiteMeasured: Value(true)));
      final measured = await advance(OrderStatus.measured);

      expect(booked, isNot(measured));
      expect(await db.pendingOutbox(), hasLength(3));

      final report = await outboxer.drain(credentials);
      expect(report.sent, [orderId, booked, measured]);
      expect(server.orderStatus[orderId], 'measured');
    });

    test('a retry of one move changes nothing', () async {
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      final eventId = await advance(OrderStatus.measurementBooked);
      await outboxer.drain(credentials);
      await outboxer.enqueueStatusChange(
        eventId,
        statusChangePayload(
          orderId: orderId,
          event: (await orders.historyOf(
            orderId,
          )).firstWhere((e) => e.id == eventId),
        ),
      );
      await outboxer.drain(credentials);

      expect(server.appliedEvents, {eventId});
      expect(server.orderStatus[orderId], 'measurement_booked');
    });

    test('a move the server refuses is reported', () async {
      // The device is offline-first and may be hours ahead. It has to learn
      // which move was rejected rather than lose the batch to an error.
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      server.refuseStatusBecause = 'not_a_transition';
      final eventId = await advance(OrderStatus.measurementBooked);
      final report = await outboxer.drain(credentials);

      expect(report.sent, [eventId]);
      expect(report.disagreed, [eventId]);
      expect(server.orderStatus[orderId], 'confirmed');
    });

    test('a cancellation carries its reason', () async {
      // §13 B3 will be settled from these rows, so the reason travels with the
      // move rather than being left on the device.
      await seed();
      await queueOrder();
      await outboxer.drain(credentials);

      await advance(OrderStatus.cancelled, reason: 'customer bought elsewhere');
      await outboxer.drain(credentials);

      final last = server.seen.last as dynamic;
      final body =
          jsonDecode(utf8.decode(last.bodyBytes as List<int>))
              as Map<String, dynamic>;
      expect(body['to'], 'cancelled');
      expect(body['reason'], 'customer bought elsewhere');
    });
  });

  test('an order and a payment drain in the order they happened', () async {
    // One queue. Neither can wait behind the other failing, and FIFO is the
    // only ordering anybody can reason about when it goes wrong.
    await seed();
    await queueOrder();
    await outboxer.enqueuePayment('pay-1', {
      'id': 'pay-1',
      'quote_id': 'q1',
      'kind': 'deposit',
      'amount_sen': 30000,
      'method': 'cash',
      'taken_at': at.toIso8601String(),
    });

    final report = await outboxer.drain(credentials);
    expect(report.sent, [orderId, 'pay-1']);
    expect((await read()).orderNo, 'MLK-2608-0001');
    expect(server.receipts['pay-1'], 'R2608-0001');
  });

  test('the money is never held up by the network', () async {
    // The deposit was taken before any of this ran. §9: offline is the
    // default, not a fallback.
    await seed();
    server.offline = true;
    await queueOrder();

    expect((await read()).depositPaidSen, 30000);
    await outboxer.drain(credentials);
    expect((await read()).depositPaidSen, 30000);
    expect(
      (await read()).orderNo,
      isNull,
      reason: 'no number yet, and the app shows "pending sync" for it',
    );
  });
}

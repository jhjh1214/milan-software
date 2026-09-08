/// The push side, and the two Phase 3 acceptance criteria that live here:
///
/// - "Quote offline for one hour, restore network, everything lands **once**"
/// - "Double-submit the same outbox row: no duplicate created"
///
/// Both are about the same thing. A fair's connection drops mid-request all
/// day, the device cannot tell a lost request from a lost response, and the
/// only safe design is one where sending twice costs nothing.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/payment_repository.dart';
import 'package:milan_quote/pricing/cash_up.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/outbox.dart';
import 'package:milan_quote/sync/quote_payload.dart';

import 'fake_server.dart';

const credentials = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Ah Lian', role: 'parttime', language: 'zh'),
);

final at = DateTime.utc(2026, 8, 15, 2);

void main() {
  late AppDatabase db;
  late FakeServer server;
  late Outboxer outboxer;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
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

  /// Writes a quote with one window and queues it, the way finishing a quote
  /// on the wizard does.
  Future<String> queueAQuote({String room = '客厅', int totalSen = 55200}) async {
    final quoteId = 'quote-${server.accepted.length}-$room';
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: quoteId,
            rateCardVersion: 1,
            createdAt: at,
            updatedAt: at,
          ),
        );
    await db
        .into(db.quoteLines)
        .insert(
          QuoteLinesCompanion.insert(
            id: '$quoteId-line',
            quoteId: quoteId,
            sortOrder: 0,
            room: room,
            variant: 'night_curtain',
            layer: 'night',
            widthTmm: 36576,
            heightTmm: const Value(27432),
            rawWidth: "12'",
            rawHeight: "9'",
            createdAt: at,
          ),
        );

    final quote = await (db.select(
      db.quotes,
    )..where((q) => q.id.equals(quoteId))).getSingle();

    await outboxer.enqueueQuote(
      quoteId,
      quotePayload(
        quote: quote,
        lines: await db.linesFor(quoteId),
        deviceTotalSen: totalSen,
        lineTotalsSen: {'$quoteId-line': totalSen},
        deviceId: 'handset-1',
      ),
    );
    return quoteId;
  }

  group('a quote taken with no signal', () {
    test('is queued rather than lost', () async {
      final id = await queueAQuote();
      final waiting = await db.pendingOutbox();
      expect(waiting, hasLength(1));
      expect(waiting.single.entityId, id);
    });

    test('lands once when the network comes back', () async {
      // The acceptance criterion. Quote offline, reconnect, everything lands
      // exactly once.
      await queueAQuote(room: '客厅');
      await queueAQuote(room: '主人房');
      await queueAQuote(room: '书房');

      final report = await outboxer.drain(credentials);

      expect(report.ok, isTrue);
      expect(report.sent, hasLength(3));
      expect(server.accepted, hasLength(3));
      expect(await db.pendingOutbox(), isEmpty);
    });

    test('the quote is stamped as synced', () async {
      final id = await queueAQuote();
      await outboxer.drain(credentials);

      final quote = await (db.select(
        db.quotes,
      )..where((q) => q.id.equals(id))).getSingle();
      expect(quote.syncedAt, at);
    });

    test('draining again sends nothing', () async {
      await queueAQuote();
      await outboxer.drain(credentials);
      final second = await outboxer.drain(credentials);

      expect(second.sent, isEmpty);
      expect(server.accepted, hasLength(1));
    });
  });

  group('double submission', () {
    test('the same row sent twice creates one quote', () async {
      // §9.2, written as a test before the endpoint existed. The device cannot
      // know whether the first attempt landed before the signal dropped.
      final id = await queueAQuote();
      final payload = (await db.pendingOutbox()).single.payload;

      await outboxer.drain(credentials);
      // Straight back onto the queue, as a lost response would leave it.
      await outboxer.enqueueQuote(
        id,
        jsonDecode(payload) as Map<String, dynamic>,
      );
      final second = await outboxer.drain(credentials);

      expect(second.sent, [id]);
      expect(server.accepted, hasLength(1));
    });

    test('a retry the server has already seen counts as sent', () async {
      // Treating `duplicate: true` as a failure would have the row retried
      // forever, and the queue would never drain.
      final id = await queueAQuote();
      final payload = (await db.pendingOutbox()).single.payload;
      await outboxer.drain(credentials);

      await outboxer.enqueueQuote(
        id,
        jsonDecode(payload) as Map<String, dynamic>,
      );
      await outboxer.drain(credentials);

      expect(await db.pendingOutbox(), isEmpty);
    });

    test('queueing one quote twice leaves one row', () async {
      // The outbox holds work to do, not a history of intentions.
      final id = await queueAQuote();
      final payload = (await db.pendingOutbox()).single.payload;
      await outboxer.enqueueQuote(
        id,
        jsonDecode(payload) as Map<String, dynamic>,
      );

      expect(await db.pendingOutbox(), hasLength(1));
    });
  });

  group('failure', () {
    test('no signal keeps the whole queue', () async {
      await queueAQuote(room: '客厅');
      await queueAQuote(room: '主人房');
      server.offline = true;

      final report = await outboxer.drain(credentials);

      expect(report.failure, SyncFailure.offline);
      expect(report.sent, isEmpty);
      expect(await db.pendingOutbox(), hasLength(2));
    });

    test(
      'a revoked session stops the drain rather than parking work',
      () async {
        // Nothing is wrong with the quotes. Parking them for an auth problem
        // would turn a sign-in into lost orders.
        await queueAQuote();
        server.validTokens.clear();

        final report = await outboxer.drain(credentials);

        expect(report.failure, SyncFailure.unauthenticated);
        expect(report.parked, isEmpty);
        expect(await db.pendingOutbox(), hasLength(1));
      },
    );

    test('the failure is recorded on the row', () async {
      await queueAQuote();
      server.offline = true;
      await outboxer.drain(credentials);

      final row = (await db.pendingOutbox()).single;
      expect(row.attempts, 1);
      expect(row.lastAttemptAt, at);
      expect(row.lastError, isNotEmpty);
    });

    test('a row the server keeps rejecting is parked, not dropped', () async {
      // It is somebody's order. Deleting it would lose a sale silently; leaving
      // it at the head of a FIFO queue would block every quote behind it.
      await queueAQuote();
      server.rejectQuotes = true;

      for (var i = 0; i < kMaxAttempts; i++) {
        await outboxer.drain(credentials);
      }

      expect(await db.pendingOutbox(), isEmpty, reason: 'no longer retried');
      final parked = await outboxer.parked();
      expect(parked, hasLength(1));
      expect(parked.single.parkedAt, at);
    });

    test('a parked row does not block the ones behind it', () async {
      await queueAQuote(room: '坏的');
      server.rejectQuotes = true;
      for (var i = 0; i < kMaxAttempts; i++) {
        await outboxer.drain(credentials);
      }

      server.rejectQuotes = false;
      await queueAQuote(room: '好的');
      final report = await outboxer.drain(credentials);

      expect(report.sent, hasLength(1));
      expect(server.accepted, hasLength(1));
    });

    test('a parked row can be put back after a fix', () async {
      await queueAQuote();
      server.rejectQuotes = true;
      for (var i = 0; i < kMaxAttempts; i++) {
        await outboxer.drain(credentials);
      }

      server.rejectQuotes = false;
      await outboxer.retryParked((await outboxer.parked()).single.id);
      final report = await outboxer.drain(credentials);

      expect(report.sent, hasLength(1));
      expect(await outboxer.parked(), isEmpty);
    });
  });

  test(
    'a pricing disagreement is reported, and the quote still lands',
    () async {
      // §9.4. Never lose a sale over a rounding dispute — but never hide it
      // either: a mismatch means the two engines have drifted.
      final id = await queueAQuote();
      server.serverTotalOverrideSen = 55100;

      final report = await outboxer.drain(credentials);

      expect(report.sent, [id]);
      expect(report.disagreed, [id]);
      expect(await db.pendingOutbox(), isEmpty);
    },
  );

  test(
    'a stale buyer-details refusal is reported, not treated as delivered',
    () async {
      // Bug hunt, 2026-09-08 (FINDINGS.md #2). `BuyerDetailsAccepted` fell
      // into drain()'s generic branch, which only checks `PushResponse` —
      // a class it isn't — so a refusal was silently dropped as a success:
      // the row vanished from the outbox and nothing was ever reported.
      await outboxer.enqueueBuyerDetails('order-1', {
        'order_id': 'order-1',
        'captured_at': at.toUtc().toIso8601String(),
        'name': 'Ah Lian',
      });
      server.refuseBuyerDetailsBecause = 'stale';

      final report = await outboxer.drain(credentials);

      expect(report.sent, ['order-1']);
      expect(report.disagreed, ['order-1']);
      expect(await db.pendingOutbox(), isEmpty);
    },
  );

  test('the queue drains oldest first', () async {
    await queueAQuote(room: 'first');
    await queueAQuote(room: 'second');
    await queueAQuote(room: 'third');

    final report = await outboxer.drain(credentials);
    expect(report.sent, [
      'quote-0-first',
      'quote-0-second',
      'quote-0-third',
    ], reason: 'a queue that reorders is one nobody can reason about');
  });

  group('payments', () {
    /// Records a payment and queues it, the way taking an RM300 does.
    Future<String> queueAPayment({
      int sen = 30000,
      String id = 'pay-1',
      String quoteId = 'quote-for-pay',
    }) async {
      await db
          .into(db.quotes)
          .insert(
            QuotesCompanion.insert(
              id: quoteId,
              rateCardVersion: 1,
              createdAt: at,
              updatedAt: at,
            ),
          );
      final repo = PaymentRepository(db);
      await repo.record(
        id: id,
        quoteId: quoteId,
        kind: PaymentKind.deposit,
        method: PaymentMethod.cash,
        amountSen: sen,
        takenAt: at,
      );
      final row = (await repo.forQuote(quoteId)).single;
      await outboxer.enqueuePayment(id, repo.pushBodyFor(row));
      return id;
    }

    test('a payment goes up and comes back with a receipt number', () async {
      // The Phase 4 acceptance criterion: recorded offline, receipt resolves
      // after sync.
      final id = await queueAPayment();
      expect(
        (await PaymentRepository(db).awaitingReceipt()).single.id,
        id,
        reason: 'until it syncs, there is no number to show',
      );

      final report = await outboxer.drain(credentials);

      expect(report.sent, [id]);
      final row = (await PaymentRepository(
        db,
      ).forQuote('quote-for-pay')).single;
      expect(row.receiptNo, 'R2608-0001');
      expect(row.status, 'settled');
      expect(row.syncedAt, at);
      expect(await PaymentRepository(db).awaitingReceipt(), isEmpty);
    });

    test('two category deposits offline, and both receipts resolve', () async {
      // The Phase 4 acceptance criterion, word for word. A curtain RM300 and a
      // flooring RM300 on one quote is a normal afternoon at one stall, and
      // both were taken with no signal.
      const quoteId = 'quote-two-categories';
      await db
          .into(db.quotes)
          .insert(
            QuotesCompanion.insert(
              id: quoteId,
              rateCardVersion: 1,
              channel: const Value('fair'),
              createdAt: at,
              updatedAt: at,
            ),
          );

      final repo = PaymentRepository(db);
      for (final id in ['pay-curtain', 'pay-flooring']) {
        await repo.record(
          id: id,
          quoteId: quoteId,
          kind: PaymentKind.deposit,
          method: PaymentMethod.cash,
          amountSen: 30000,
          takenAt: at,
        );
      }

      server.offline = true;
      for (final row in await repo.forQuote(quoteId)) {
        await outboxer.enqueuePayment(row.id, repo.pushBodyFor(row));
      }

      // Both are money already in the tin, and neither has a number yet.
      expect((await repo.awaitingReceipt()).length, 2);
      expect((await outboxer.drain(credentials)).failure, SyncFailure.offline);
      expect((await repo.awaitingReceipt()).length, 2);

      server.offline = false;
      final report = await outboxer.drain(credentials);

      expect(report.sent, ['pay-curtain', 'pay-flooring']);
      expect(
        await repo.awaitingReceipt(),
        isEmpty,
        reason: 'both receipts resolve after sync',
      );

      final numbers = [
        for (final row in await repo.forQuote(quoteId)) row.receiptNo,
      ];
      expect(numbers, ['R2608-0001', 'R2608-0002']);
      expect(
        numbers.toSet().length,
        2,
        reason:
            'two payments, two numbers — one shared number would be one '
            'receipt for money taken twice',
      );
    });
    test('a retry does not take the money twice', () async {
      // The worst failure in the system: charging RM600 because a connection
      // dropped once.
      final id = await queueAPayment();
      await outboxer.drain(credentials);

      final repo = PaymentRepository(db);
      final row = (await repo.forQuote('quote-for-pay')).single;
      await outboxer.enqueuePayment(id, repo.pushBodyFor(row));
      await outboxer.drain(credentials);

      expect(server.receipts, hasLength(1));
      expect((await repo.forQuote('quote-for-pay')), hasLength(1));
    });

    test('a retry keeps the receipt number it was already given', () async {
      // The customer may already be holding a printed one.
      final id = await queueAPayment();
      await outboxer.drain(credentials);
      final first = (await PaymentRepository(
        db,
      ).forQuote('quote-for-pay')).single.receiptNo;

      final repo = PaymentRepository(db);
      final row = (await repo.forQuote('quote-for-pay')).single;
      await outboxer.enqueuePayment(id, repo.pushBodyFor(row));
      await outboxer.drain(credentials);

      expect((await repo.forQuote('quote-for-pay')).single.receiptNo, first);
    });

    test('no signal leaves the payment queued and unnumbered', () async {
      await queueAPayment();
      server.offline = true;

      final report = await outboxer.drain(credentials);

      expect(report.failure, SyncFailure.offline);
      expect(await db.pendingOutbox(), hasLength(1));
      expect(
        (await PaymentRepository(
          db,
        ).forQuote('quote-for-pay')).single.receiptNo,
        isNull,
        reason: 'the device never invents one while it waits',
      );
    });

    test('the body carries no receipt number on the way up', () async {
      await queueAPayment();
      final body =
          jsonDecode((await db.pendingOutbox()).single.payload)
              as Map<String, dynamic>;

      expect(body.containsKey('receipt_no'), isFalse);
      expect(body['amount_sen'], 30000);
      expect(body['method'], 'cash');
    });

    test('quotes and payments drain from the one queue, in order', () async {
      // A payment must not wait behind a quote, and a quote must not wait
      // behind a payment. They happened in an order and they leave in it.
      await queueAQuote(room: '客厅');
      await queueAPayment();

      final report = await outboxer.drain(credentials);
      expect(report.sent, hasLength(2));
      expect(await db.pendingOutbox(), isEmpty);
    });
  });

  test('the payload is frozen at enqueue, not rebuilt at send', () async {
    // What goes up is what the customer was shown. Rebuilding it at send time
    // would push a quote the customer never saw.
    final id = await queueAQuote(totalSen: 55200);
    await (db.update(db.quotes)..where((q) => q.id.equals(id))).write(
      QuotesCompanion(customerName: const Value('edited later')),
    );

    await outboxer.drain(credentials);
    final body =
        jsonDecode(utf8.decode(server.lastQuoteBody!)) as Map<String, dynamic>;
    expect(body['customer_name'], isNull);
  });
}

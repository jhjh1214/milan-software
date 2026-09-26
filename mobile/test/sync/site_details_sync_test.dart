/// Where a visit is, from the fair table to the office. §13 C10.
///
/// Taken on the quote, it has to ride the order push; filled in later, it has
/// to go up on its own and a refusal must be said rather than swallowed.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/order_repository.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/order_payload.dart';
import 'package:milan_quote/sync/outbox.dart';

import 'fake_server.dart';

const credentials = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Ah Lian', role: 'parttime', language: 'zh'),
);

final confirmedAt = DateTime.utc(2026, 8, 29, 3);

void main() {
  late AppDatabase db;
  late FakeServer server;
  late Outboxer outboxer;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    server = FakeServer();
    outboxer = Outboxer(
      db: db,
      api: ApiClient(
        baseUrl: Uri.parse('https://example.test'),
        client: server.client,
        timeout: const Duration(milliseconds: 200),
      ),
      clock: () => confirmedAt,
    );
    await db
        .into(db.quotes)
        .insert(
          QuotesCompanion.insert(
            id: 'q-1',
            rateCardVersion: 1,
            createdAt: confirmedAt,
            updatedAt: confirmedAt,
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
            estimateTotalSen: 55200,
            confirmedAt: confirmedAt,
            siteAddress: const Value('3 Jalan Bunga'),
            sitePostcode: const Value('75450'),
            siteReadyFrom: Value(DateTime(2026, 11, 1)),
          ),
        );
  });

  tearDown(() => db.close());

  Future<OrderRow> theOrder() =>
      (db.select(db.orders)..where((o) => o.id.equals('o-1'))).getSingle();

  test('an address taken at the fair rides the order push', () async {
    final body = orderPayload(
      order: await theOrder(),
      lines: const [],
      events: const [],
      overrides: const [],
    );
    expect(body['site_address_note'], '3 Jalan Bunga');
    expect(body['site_postcode'], '75450');
    // A calendar day, never an instant a timezone could move.
    expect(body['site_ready_from'], '2026-11-01');
  });

  test('a later capture is recorded, stamped, and goes up whole', () async {
    final at = DateTime.utc(2026, 9, 2, 4);
    await OrderRepository(db).recordSiteDetails(
      orderId: 'o-1',
      address: '12 Jalan Melati',
      postcode: '75000',
      readyFrom: null,
      at: at,
    );
    final order = await theOrder();
    expect(order.siteCapturedAt, at);

    await outboxer.enqueueSiteDetails(
      'o-1',
      siteDetailsPayload(order: order, capturedAt: at),
    );
    final report = await outboxer.drain(credentials);

    expect(report.sent, ['o-1']);
    expect(report.disagreed, isEmpty);
    expect(server.lastSiteDetailsBody, {
      'order_id': 'o-1',
      'captured_at': '2026-09-02T04:00:00.000Z',
      'site_address_note': '12 Jalan Melati',
      'site_postcode': '75000',
      // Cleared explicitly: the whole record replaces what the server holds.
      'site_ready_from': null,
    });
  });

  test('a stale capture is reported, not treated as delivered', () async {
    // The office typed something newer from the dashboard; that stands, and
    // the handset has to hear that its version did not.
    server.refuseSiteDetailsBecause = 'stale';
    await outboxer.enqueueSiteDetails(
      'o-1',
      siteDetailsPayload(order: await theOrder(), capturedAt: confirmedAt),
    );
    final report = await outboxer.drain(credentials);

    expect(report.sent, ['o-1']);
    expect(report.disagreed, ['o-1']);
    expect(await db.pendingOutbox(), isEmpty);
  });

  test('a newer capture replaces an older one still waiting', () async {
    await outboxer.enqueueSiteDetails('o-1', {'order_id': 'o-1', 'v': 1});
    await outboxer.enqueueSiteDetails('o-1', {'order_id': 'o-1', 'v': 2});
    final pending = await db.pendingOutbox();
    expect(pending, hasLength(1));
    expect(pending.single.payload, contains('"v":2'));
  });
}

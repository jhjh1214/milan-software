/// Prices are server-owned from Phase 3 on.
///
/// The acceptance criterion in SPEC.md §11 is "publish a rate change; every
/// device picks it up on next connect", and the invariant underneath it is
/// that a device cannot keep quoting its own prices. These tests are mostly
/// about the second one.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/rate_card_sync.dart';

import 'fake_server.dart';

const credentials = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Ah Lian', role: 'parttime', language: 'zh'),
);

final at = DateTime.utc(2026, 8, 15, 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> fairCard;
  late Map<String, dynamic> standardCard;

  setUpAll(() async {
    fairCard =
        jsonDecode(
              await rootBundle.loadString(
                'assets/data/rate-card-fair-2026-08.json',
              ),
            )
            as Map<String, dynamic>;
    standardCard =
        jsonDecode(
              await rootBundle.loadString(
                'assets/data/rate-card-standard.json',
              ),
            )
            as Map<String, dynamic>;
  });

  /// A store backed by memory, reading the shipped cards without the bundle.
  RateCardStore storeOver(InMemoryRateCardStorage storage) => RateCardStore(
    storage: storage,
    bundled: (list) async =>
        jsonEncode(list == PriceList.fair ? fairCard : standardCard),
  );

  ({RateCardSync sync, RateCardStore store, FakeServer server}) harness({
    Map<String, Map<String, dynamic>>? cards,
    InMemoryRateCardStorage? storage,
  }) {
    final server = FakeServer(
      cards: cards ?? {'fair': fairCard, 'standard': standardCard},
    );
    final store = storeOver(storage ?? InMemoryRateCardStorage());
    return (
      sync: RateCardSync(
        api: ApiClient(
          baseUrl: Uri.parse('https://example.test'),
          client: server.client,
        ),
        store: store,
        clock: () => at,
      ),
      store: store,
      server: server,
    );
  }

  group('a fresh handset', () {
    test('starts on the bundled card so it can quote on day one', () async {
      // A fair with no signal on the first morning is a normal Tuesday, not an
      // edge case.
      final h = harness();
      final held = await h.store.provenance(PriceList.fair);
      expect(held.origin, RateCardOrigin.bundled);
      expect(held.version, 1);
      expect((await h.store.load(PriceList.fair)).version, 1);
    });

    test('adopts the server card on the first pull', () async {
      final h = harness();
      final result = await h.sync.pull(credentials);

      expect(result.ok, isTrue);
      expect(result.updated[PriceList.fair], 1);
      final held = await h.store.provenance(PriceList.fair);
      expect(held.origin, RateCardOrigin.server);
      expect(held.fetchedAt, at);
    });

    test('pulls both lists, not only the one in force today', () async {
      // A fair in August has to already hold September's standard list. The
      // day it switches over is not a day anyone has a connection to spare.
      final h = harness();
      final result = await h.sync.pull(credentials);
      expect(result.updated.keys, containsAll(PriceList.values));
    });
  });

  group('a published price change', () {
    test('reaches the device on its next connect', () async {
      // The Phase 3 acceptance criterion, from the device's side.
      final h = harness();
      await h.sync.pull(credentials);
      expect((await h.store.load(PriceList.fair)).version, 1);

      h.server.cards['fair'] = _repriced(fairCard, version: 2, sen: 5000);
      final second = await h.sync.pull(credentials);

      expect(second.updated[PriceList.fair], 2);
      final card = await h.store.load(PriceList.fair);
      expect(card.version, 2);
      expect(
        card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        5000,
        reason: 'the price moved, and no code did',
      );
    });

    test('an unchanged card costs no payload', () async {
      // §9.1. A fair's connection is thin and shared; re-downloading a card the
      // phone already has is the kind of waste that shows up as a spinner in
      // front of a customer.
      final h = harness();
      await h.sync.pull(credentials);

      final second = await h.sync.pull(credentials);
      expect(second.alreadyCurrent, containsAll(PriceList.values));
      expect(second.updated, isEmpty);

      final asked = h.server.seen
          .where((r) => r.url.path == '/api/bundle')
          .map((r) => r.url.queryParameters['since_version'])
          .toList();
      expect(asked, contains('1'), reason: 'the device says what it holds');
    });
  });

  group('a Phase 2 local edit', () {
    test('is replaced by the server card', () async {
      // The whole reason prices became server-owned. Six handsets each holding
      // their own edited list is six handsets quoting six different prices.
      final storage = InMemoryRateCardStorage();
      final h = harness(storage: storage);
      await h.store.save(
        PriceList.fair,
        _repriced(fairCard, version: 99, sen: 9900),
      );
      expect(
        (await h.store.provenance(PriceList.fair)).origin,
        RateCardOrigin.local,
      );

      final result = await h.sync.pull(credentials);

      expect(result.discardedLocalEdit, isTrue);
      final card = await h.store.load(PriceList.fair);
      expect(card.version, 1);
      expect(
        card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        4600,
      );
    });

    test('is replaced even when its version matches the server', () async {
      // The version on a local edit was invented on the device. Comparing it
      // against the server's is meaningless, and a coincidental match would
      // leave a hand-typed price in place forever — silently.
      final h = harness();
      await h.store.save(
        PriceList.fair,
        _repriced(fairCard, version: 1, sen: 9900),
      );

      await h.sync.pull(credentials);

      final card = await h.store.load(PriceList.fair);
      expect(
        card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        4600,
      );
    });

    test('a card stored before provenance existed counts as local', () async {
      // An app updated across the Phase 2 to Phase 3 boundary has a card file
      // and no note beside it. Assuming `server` would exempt exactly the
      // edits this is here to clear.
      final storage = InMemoryRateCardStorage();
      await storage.write(PriceList.fair.id, jsonEncode(fairCard));
      final h = harness(storage: storage);

      expect(
        (await h.store.provenance(PriceList.fair)).origin,
        RateCardOrigin.local,
      );
    });
  });

  group('no signal', () {
    test('a failed pull leaves the handset quoting', () async {
      // CLAUDE.md rule 9: offline is the default, not a fallback.
      final h = harness();
      h.server.offline = true;

      final result = await h.sync.pull(credentials);

      expect(result.ok, isFalse);
      expect(result.failure, SyncFailure.offline);
      expect((await h.store.load(PriceList.fair)).version, 1);
    });

    test('a hung connection gives up rather than spinning', () async {
      // At a fair the connection does not fail, it hangs. A spinner that never
      // resolves is worse than a failure, because nobody knows to carry on.
      final server = FakeServer(cards: {'fair': fairCard})..hang = true;
      final sync = RateCardSync(
        api: ApiClient(
          baseUrl: Uri.parse('https://example.test'),
          client: server.client,
          timeout: const Duration(milliseconds: 50),
        ),
        store: storeOver(InMemoryRateCardStorage()),
        clock: () => at,
      );

      final result = await sync.pull(credentials);
      expect(result.failure, SyncFailure.offline);
    });

    test('a revoked session is reported as such, not as offline', () async {
      // They mean different things to the user: one is "wait", the other is
      // "sign in again".
      final h = harness();
      h.server.validTokens.clear();

      final result = await h.sync.pull(credentials);
      expect(result.failure, SyncFailure.unauthenticated);
    });

    test('a token killed mid-fair leaves the handset quoting', () async {
      // The Phase 3 acceptance criterion. An admin revokes a lost phone, or a
      // session is ended by mistake, and the part-timer holding it is halfway
      // through a customer. The card already pulled is still there and still
      // prices.
      final h = harness();
      await h.sync.pull(credentials);

      h.server.validTokens.clear();
      final result = await h.sync.pull(credentials);

      expect(result.failure, SyncFailure.unauthenticated);
      final card = await h.store.load(PriceList.fair);
      expect(card.version, 1);
      expect(
        card.rules.firstWhere((r) => r.id == 'night-curtain-lo').rateSen,
        4600,
        reason: 'the prices it already had are untouched',
      );
      expect(
        (await h.store.provenance(PriceList.fair)).origin,
        RateCardOrigin.server,
      );
    });

    test('what landed before a failure is kept', () async {
      // Stopping at the first failure must not roll back the list that already
      // arrived — that would waste the only connection of the day.
      final h = harness(cards: {'fair': fairCard});
      final result = await h.sync.pull(credentials);

      expect(result.updated[PriceList.fair], 1);
      expect(result.failure, isNotNull, reason: 'standard is missing: 404');
      expect(
        (await h.store.provenance(PriceList.fair)).origin,
        RateCardOrigin.server,
      );
    });
  });

  test('a card the engine cannot read is refused, not stored', () async {
    // An older handset meeting a newer card format. Storing it would overwrite
    // the working card with one that cannot price a line, leaving the handset
    // unable to quote at all — and throwing would be a crash in front of a
    // customer.
    final h = harness(
      cards: {
        'fair': {'version': 7, 'nonsense': true},
      },
    );

    final result = await h.sync.pull(credentials);

    expect(result.failure, SyncFailure.serverError);
    expect((await h.store.load(PriceList.fair)).version, 1);
    expect(
      (await h.store.provenance(PriceList.fair)).origin,
      RateCardOrigin.bundled,
      reason: 'the good card is still the one in force',
    );
  });
}

/// A copy of [card] at [version] with the plain night-curtain rate moved.
Map<String, dynamic> _repriced(
  Map<String, dynamic> card, {
  required int version,
  required int sen,
}) {
  final copy = jsonDecode(jsonEncode(card)) as Map<String, dynamic>;
  copy['version'] = version;
  for (final rule in (copy['rules'] as List).cast<Map<String, dynamic>>()) {
    if (rule['id'] == 'night-curtain-lo') rule['rate_sen'] = sen;
  }
  return copy;
}

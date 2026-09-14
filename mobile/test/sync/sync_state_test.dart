/// `SyncController.syncNow()`'s own `GET /api/auth/me` check, added to close
/// a real gap: the route existed, was tested, and its own docstring already
/// said what it was for ("notice a revoked session, and to pick up a role
/// or language changed in the office") -- nothing on the handset ever
/// called it. `CredentialsNotifier` had a related, separate gap: a restored
/// session's language never re-seeded `languageProvider`.
///
/// `SyncController` had no unit coverage before this file at all -- every
/// test here is new, not a rewrite.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/rate_card_store.dart';
import 'package:milan_quote/features/quote/quote_state.dart';
import 'package:milan_quote/sync/api_client.dart';
import 'package:milan_quote/sync/session_store.dart';
import 'package:milan_quote/sync/sync_state.dart';

import 'fake_server.dart';

const startingCredentials = Credentials(
  token: 'good-token',
  user: Identity(id: 'u1', name: 'Ah Lian', role: 'staff', language: 'en'),
);

void main() {
  late FakeServer server;
  late ProviderContainer container;

  /// Builds a container with a session already on disk (the way a relaunch
  /// finds one) and every provider `syncNow()` touches pointed at the fake
  /// server / memory, never the real network or a real database.
  Future<ProviderContainer> harness({Credentials? seeded}) async {
    // No token valid by default -- each test that wants a live session
    // opts in explicitly, so "revoked" is the harness's own baseline rather
    // than something a test has to arrange. A plain mutable set: FakeServer
    // otherwise defaults to one that already contains 'good-token'.
    server = FakeServer(cards: const {}, tokens: <String>{});
    final sessionStore = InMemorySessionStore(seeded);

    final c = ProviderContainer(
      overrides: [
        secureStoreProvider.overrideWithValue(
          SecureStores(session: sessionStore),
        ),
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: Uri.parse('https://example.test'),
            client: server.client,
            timeout: const Duration(milliseconds: 200),
          ),
        ),
        databaseProvider.overrideWithValue(
          AppDatabase(NativeDatabase.memory()),
        ),
        rateCardStoreProvider.overrideWithValue(
          RateCardStore(
            storage: InMemoryRateCardStorage(),
            // `provenance()` reads this to learn the bundled version even
            // with nothing stored locally yet, before `pull()` ever talks
            // to the network -- a minimal but real card, not the shipped
            // one, since nothing here prices anything.
            bundled: (list) async => jsonEncode({
              'version': 1,
              'config': {'min_deposit_sen': 30000, 'band_edge_warn_tmm': 100},
              'rules': <Map<String, dynamic>>[],
            }),
          ),
        ),
      ],
    );
    // `credentialsProvider` reads the session store asynchronously;
    // `syncNow()` reads it synchronously, so every test awaits it resolved
    // first, the way the real app's widget tree does by rendering a loading
    // state until it settles.
    await c.read(credentialsProvider.future);
    return c;
  }

  tearDown(() {
    container.dispose();
  });

  test(
    'a revoked token signs out immediately, before ever asking for prices',
    () async {
      container = await harness(seeded: startingCredentials);

      final status = await container.read(syncProvider.notifier).syncNow();

      expect(status.signedOut, isTrue);
      expect(container.read(credentialsProvider).valueOrNull, isNull);
      // The whole point: a revoked session gets exactly the one request that
      // discovers it, never a price pull spent on a token already dead.
      expect(server.seen, hasLength(1));
      expect(server.seen.single.url.path, '/api/auth/me');
    },
  );

  test('picks up a role and language changed in the office', () async {
    container = await harness(seeded: startingCredentials);
    server.validTokens.add('good-token');
    server.meResponse = const {
      'id': 'u1',
      'name': 'Ah Lian',
      'role': 'admin',
      'language': 'zh',
    };

    await container.read(syncProvider.notifier).syncNow();

    final held = container.read(credentialsProvider).valueOrNull;
    expect(held?.user.role, 'admin');
    expect(held?.user.language, 'zh');
    expect(container.read(languageProvider), 'zh');
    // The token itself is not reissued by this route.
    expect(held?.token, 'good-token');
  });

  test('an unchanged identity does not rewrite the stored session', () async {
    container = await harness(seeded: startingCredentials);
    server.validTokens.add('good-token');
    server.meResponse = const {
      'id': 'u1',
      'name': 'Ah Lian',
      'role': 'staff',
      'language': 'en',
    };

    await container.read(syncProvider.notifier).syncNow();

    expect(
      container.read(credentialsProvider).valueOrNull,
      startingCredentials,
    );
  });

  test('offline never gates the rest of a sync -- hard rule 9', () async {
    container = await harness(seeded: startingCredentials);
    server.offline = true;

    final status = await container.read(syncProvider.notifier).syncNow();

    // me() failed offline same as everything else would; syncNow() carried
    // on to the pull rather than stopping dead on the me() call specifically.
    expect(status.signedOut, isFalse);
    expect(status.offline, isTrue);
    expect(
      container.read(credentialsProvider).valueOrNull,
      startingCredentials,
    );
  });

  test('nothing happens with no session to confirm', () async {
    container = await harness();
    final status = await container.read(syncProvider.notifier).syncNow();
    expect(status.running, isFalse);
    expect(server.seen, isEmpty);
  });

  test(
    'a restored session re-seeds the language it was signed in with',
    () async {
      container = await harness(
        seeded: const Credentials(
          token: 'good-token',
          user: Identity(
            id: 'u1',
            name: 'Ah Lian',
            role: 'parttime',
            language: 'ms',
          ),
        ),
      );

      // build() already ran inside harness()'s own await; a force-quit and
      // reopen must not leave the app speaking whatever languageProvider
      // defaults to.
      expect(container.read(languageProvider), 'ms');
    },
  );
}

/// Wiring sync into the app. Riverpod, per CLAUDE.md.
///
/// The rule every provider here obeys: **nothing blocks on the network.** The
/// quote screen builds, prices and prints with no session, no signal and no
/// server. Sync is something that happens beside the app, never in front of it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/quote_repository.dart' show newId;
import '../data/rate_card_store.dart';
import '../features/quote/quote_state.dart';
import 'api_client.dart';
import 'outbox.dart';
import 'rate_card_sync.dart';
import 'server_config.dart';
import 'session_store.dart';

/// Where the session and the server address are kept. Overridden in tests.
final secureStoreProvider = Provider<SecureStores>((ref) => SecureStores());

final serverConfigProvider =
    AsyncNotifierProvider<ServerConfigNotifier, ServerConfig>(
      ServerConfigNotifier.new,
    );

class ServerConfigNotifier extends AsyncNotifier<ServerConfig> {
  @override
  Future<ServerConfig> build() => ref.watch(secureStoreProvider).server.read();

  /// Points the handset at a different server. Admin-only in the UI, and
  /// signing out is forced: a token issued by one server means nothing to
  /// another.
  Future<void> setBaseUrl(Uri url) async {
    final config = ServerConfig(baseUrl: url);
    await ref.read(secureStoreProvider).server.write(config);
    await ref.read(credentialsProvider.notifier).signOutLocally();
    state = AsyncData(config);
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(serverConfigProvider).valueOrNull;
  final client = ApiClient(
    baseUrl: config?.baseUrl ?? ServerConfig.fallback.baseUrl,
  );
  ref.onDispose(client.close);
  return client;
});

/// This handset's own id, stable across launches.
///
/// Client-generated like every other id here. It is what lets an admin revoke
/// one phone rather than everybody's session.
final deviceIdProvider = FutureProvider<String>(
  (ref) => ref.watch(secureStoreProvider).deviceId(),
);

final credentialsProvider =
    AsyncNotifierProvider<CredentialsNotifier, Credentials?>(
      CredentialsNotifier.new,
    );

class CredentialsNotifier extends AsyncNotifier<Credentials?> {
  @override
  Future<Credentials?> build() => ref.watch(secureStoreProvider).session.read();

  /// Signs in. Once, before the fair — the session never expires.
  Future<SyncResult<Credentials>> signIn({
    required String phone,
    required String pin,
    String? label,
  }) async {
    final deviceId = await ref.read(deviceIdProvider.future);
    final result = await ref
        .read(apiClientProvider)
        .login(phone: phone, pin: pin, deviceId: deviceId, deviceLabel: label);

    if (result case SyncOk(:final value)) {
      await ref.read(secureStoreProvider).session.write(value);
      state = AsyncData(value);
      // The user's own language, not the device's (§8.3). Someone who reads
      // only Malay must find the app in Malay on any handset they pick up.
      ref.read(languageProvider.notifier).state = value.user.language;
    }
    return result;
  }

  /// Ends the session on the server too, if there is any signal.
  ///
  /// The local half happens either way. Refusing to sign out because the
  /// network is down would strand a handset that is being handed to someone
  /// else.
  Future<void> signOut() async {
    final held = state.valueOrNull;
    if (held != null) {
      await ref.read(apiClientProvider).logout(held.token);
    }
    await signOutLocally();
  }

  Future<void> signOutLocally() async {
    await ref.read(secureStoreProvider).session.clear();
    state = const AsyncData(null);
  }
}

final rateCardSyncProvider = Provider<RateCardSync>(
  (ref) => RateCardSync(
    api: ref.watch(apiClientProvider),
    store: ref.watch(rateCardStoreProvider),
  ),
);

final outboxerProvider = Provider<Outboxer>(
  (ref) => Outboxer(
    db: ref.watch(databaseProvider),
    api: ref.watch(apiClientProvider),
  ),
);

/// How many quotes are waiting to go up. Shown, never blocked on.
///
/// Refreshed by the two things that move it — queueing a finished quote, and
/// draining — rather than watched. See [AppDatabase.outboxDepth].
final outboxDepthProvider = FutureProvider<int>(
  (ref) => ref.watch(databaseProvider).outboxDepth(),
);

/// What the last sync did, for the one line the UI shows about it.
class SyncStatus {
  final bool running;
  final DateTime? lastSuccessAt;
  final SyncFailure? lastFailure;

  /// Lists whose prices changed on the last run.
  final List<PriceList> pricesUpdated;

  /// True when a leftover Phase 2 on-device edit was replaced. Worth telling
  /// an admin: the price they typed is gone.
  final bool discardedLocalEdit;

  final int quotesSent;
  final int quotesParked;

  /// Quotes the server priced differently. Accepted, and raised for review.
  final int disagreements;

  const SyncStatus({
    this.running = false,
    this.lastSuccessAt,
    this.lastFailure,
    this.pricesUpdated = const [],
    this.discardedLocalEdit = false,
    this.quotesSent = 0,
    this.quotesParked = 0,
    this.disagreements = 0,
  });

  bool get signedOut => lastFailure == SyncFailure.unauthenticated;
  bool get offline => lastFailure == SyncFailure.offline;

  SyncStatus copyWith({
    bool? running,
    DateTime? lastSuccessAt,
    SyncFailure? lastFailure,
    bool clearFailure = false,
    List<PriceList>? pricesUpdated,
    bool? discardedLocalEdit,
    int? quotesSent,
    int? quotesParked,
    int? disagreements,
  }) => SyncStatus(
    running: running ?? this.running,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    pricesUpdated: pricesUpdated ?? this.pricesUpdated,
    discardedLocalEdit: discardedLocalEdit ?? this.discardedLocalEdit,
    quotesSent: quotesSent ?? this.quotesSent,
    quotesParked: quotesParked ?? this.quotesParked,
    disagreements: disagreements ?? this.disagreements,
  );
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(
  SyncController.new,
);

class SyncController extends Notifier<SyncStatus> {
  @override
  SyncStatus build() => const SyncStatus();

  /// One pass: prices down, then quotes up.
  ///
  /// That order on purpose. Prices are what the next customer will be quoted,
  /// and a queue of finished quotes can wait another minute; if the connection
  /// only lasts for one of the two, it should be the one that affects what
  /// happens next.
  ///
  /// Safe to call on launch, on reconnect, and from a button. Returns quietly
  /// when there is no session — never a prompt, because a prompt in the middle
  /// of a quote is worse than being out of date.
  Future<SyncStatus> syncNow() async {
    final credentials = ref.read(credentialsProvider).valueOrNull;
    if (credentials == null || state.running) return state;

    state = state.copyWith(running: true, clearFailure: true);

    final pull = await ref.read(rateCardSyncProvider).pull(credentials);
    if (pull.changedAnything) {
      // The card in force changed underneath the quote screen, so anything
      // derived from it has to be rebuilt.
      ref.invalidate(rateCardStoreProvider);
      ref.invalidate(activeRateCardProvider);
    }

    if (!pull.ok) {
      state = state.copyWith(
        running: false,
        lastFailure: pull.failure,
        pricesUpdated: pull.updated.keys.toList(growable: false),
        discardedLocalEdit: pull.discardedLocalEdit,
      );
      return state;
    }

    final drain = await ref.read(outboxerProvider).drain(credentials);
    // The badge is a snapshot, not a subscription, so the two places that
    // change the queue refresh it themselves. This is one of them.
    ref.invalidate(outboxDepthProvider);

    state = SyncStatus(
      running: false,
      lastSuccessAt: drain.ok ? DateTime.now() : state.lastSuccessAt,
      lastFailure: drain.failure,
      pricesUpdated: pull.updated.keys.toList(growable: false),
      discardedLocalEdit: pull.discardedLocalEdit,
      quotesSent: drain.sent.length,
      quotesParked: drain.parked.length,
      disagreements: drain.disagreed.length,
    );

    if (state.signedOut) {
      // The server has revoked this handset. Clearing the token locally is what
      // makes the sign-in screen appear; the quotes stay queued and go up under
      // whoever signs in next.
      await ref.read(credentialsProvider.notifier).signOutLocally();
    }
    return state;
  }

  /// "Fair mode": everything the handset needs for four days with no signal.
  ///
  /// Both price lists current, and the queue emptied so a dropped phone costs
  /// nothing that has not already reached the office. Run deliberately, before
  /// leaving, rather than hoped for at the venue.
  Future<SyncStatus> prepareForFair() => syncNow();
}

/// The handset's own id, and where the token lives.
class SecureStores {
  final SessionStore session;
  final ServerConfigStore server;
  final Future<String> Function() _deviceId;

  SecureStores({
    SessionStore? session,
    ServerConfigStore? server,
    Future<String> Function()? deviceId,
  }) : session = session ?? SecureSessionStore(),
       server = server ?? SecureServerConfigStore(),
       _deviceId = deviceId ?? _persistentDeviceId;

  Future<String> deviceId() => _deviceId();
}

Future<String> _persistentDeviceId() async {
  final store = SecureServerConfigStore();
  final existing = await store.readDeviceId();
  if (existing != null) return existing;
  final made = newId();
  await store.writeDeviceId(made);
  return made;
}

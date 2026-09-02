/// Where the session token lives on the handset.
///
/// It never expires (SPEC.md §12), so the threat is not a stale token — it is a
/// phone left on a table at a fair. The Keystore is the right home for it:
/// other apps cannot read it, and it survives an app update.
///
/// An interface, because `flutter_secure_storage` is a platform channel and
/// there is no platform inside `flutter test`. Without this seam the sync tests
/// could not exist at all.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

abstract interface class SessionStore {
  Future<Credentials?> read();
  Future<void> write(Credentials credentials);
  Future<void> clear();
}

/// The real one. Android Keystore / iOS Keychain.
class SecureSessionStore implements SessionStore {
  static const _key = 'milan.session';

  final FlutterSecureStorage _storage;

  SecureSessionStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Defaults on v11 are already AES-GCM with an RSA-OAEP wrapped key
            // in the Keystore. Two things are named explicitly because they
            // are decisions, not defaults to inherit quietly:
            //
            // - biometrics stay OFF. Requiring a fingerprint to open the app
            //   would lock out a part-timer with wet hands at an outdoor fair,
            //   which is the exact failure SPEC.md §12 forbids.
            // - resetOnError discards the token if the Keystore entry cannot
            //   be read after an OS update. The cost is one sign-in; the
            //   alternative is an app that will not open.
            aOptions: AndroidOptions(
              enforceBiometrics: false,
              resetOnError: true,
              preferencesKeyPrefix: 'milan',
            ),
          );

  @override
  Future<Credentials?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return Credentials.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Unreadable — an interrupted write, or a format change across an
      // update. Throw it away rather than crashing on every launch; the cost
      // is one sign-in, and the alternative is an app nobody can open.
      await _storage.delete(key: _key);
      return null;
    }
  }

  @override
  Future<void> write(Credentials credentials) =>
      _storage.write(key: _key, value: jsonEncode(credentials.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// For tests, and for the desktop demo build where there is no Keystore.
class InMemorySessionStore implements SessionStore {
  Credentials? _held;

  InMemorySessionStore([this._held]);

  @override
  Future<Credentials?> read() async => _held;

  @override
  Future<void> write(Credentials credentials) async => _held = credentials;

  @override
  Future<void> clear() async => _held = null;
}

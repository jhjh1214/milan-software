/// Which server this handset talks to, and its own id.
///
/// The address is a build-time default that can be changed on the device,
/// because the same APK is installed on a demo phone, a staging box and the
/// client's own VPS, and rebuilding to point it somewhere else is not a thing
/// anyone does at a fair.
///
/// It is kept in the same secure storage as the token. Not because a hostname
/// is a secret — it is not — but because a token is only valid for the server
/// that issued it, so the two belong together and are cleared together.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the app points when nothing has been configured.
///
///     flutter build apk --dart-define=MILAN_API_URL=https://milan.example.com
const String _compiledInUrl = String.fromEnvironment(
  'MILAN_API_URL',
  defaultValue: 'https://milan.example.com',
);

class ServerConfig {
  final Uri baseUrl;

  const ServerConfig({required this.baseUrl});

  /// What to use before anything has been stored or read.
  static ServerConfig get fallback =>
      ServerConfig(baseUrl: Uri.parse(_compiledInUrl));

  /// Rejects anything that is not a plain https origin.
  ///
  /// http is refused outright rather than warned about. A PIN and a
  /// non-expiring token cross this connection, and a fair's wifi is a stranger's
  /// wifi.
  static Uri? parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final url = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    if (url == null || url.host.isEmpty) return null;
    if (url.scheme != 'https') return null;
    return Uri(
      scheme: 'https',
      host: url.host,
      port: url.hasPort ? url.port : null,
    );
  }
}

abstract interface class ServerConfigStore {
  Future<ServerConfig> read();
  Future<void> write(ServerConfig config);
  Future<String?> readDeviceId();
  Future<void> writeDeviceId(String id);
}

class SecureServerConfigStore implements ServerConfigStore {
  static const _urlKey = 'milan.server';
  static const _deviceKey = 'milan.device';

  final FlutterSecureStorage _storage;

  SecureServerConfigStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<ServerConfig> read() async {
    final raw = await _storage.read(key: _urlKey);
    final parsed = raw == null ? null : ServerConfig.parse(raw);
    return parsed == null
        ? ServerConfig.fallback
        : ServerConfig(baseUrl: parsed);
  }

  @override
  Future<void> write(ServerConfig config) =>
      _storage.write(key: _urlKey, value: config.baseUrl.toString());

  @override
  Future<String?> readDeviceId() => _storage.read(key: _deviceKey);

  @override
  Future<void> writeDeviceId(String id) =>
      _storage.write(key: _deviceKey, value: id);
}

/// For tests and for the desktop demo build, where there is no Keystore.
class InMemoryServerConfigStore implements ServerConfigStore {
  ServerConfig _config;
  String? _deviceId;

  InMemoryServerConfigStore({ServerConfig? config, String? deviceId})
    : _config = config ?? ServerConfig.fallback,
      _deviceId = deviceId;

  @override
  Future<ServerConfig> read() async => _config;

  @override
  Future<void> write(ServerConfig config) async => _config = config;

  @override
  Future<String?> readDeviceId() async => _deviceId;

  @override
  Future<void> writeDeviceId(String id) async => _deviceId = id;
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  static const _kToken = 'api_token';
  static const _kServerUrl = 'server_url';
  static const _kDeviceId = 'device_id';

  final FlutterSecureStorage _storage;

  SecureStore({FlutterSecureStorage? storage})
      // encryptedSharedPreferences=true is deprecated in flutter_secure_storage
      // 9.x and causes hangs on some Samsung/Android 13+ devices because Tink
      // boot blocks the first read. Default (Android Keystore-backed prefs) is
      // fast and reliable.
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> getToken() => _storage.read(key: _kToken);
  Future<String?> getServerUrl() => _storage.read(key: _kServerUrl);

  /// Stable per-install device identity, minted at first pairing/sync and
  /// reused forever after — the server must see ONE device per install,
  /// not one per pairing attempt.
  Future<String?> getDeviceId() => _storage.read(key: _kDeviceId);

  Future<void> setDeviceId(String id) =>
      _storage.write(key: _kDeviceId, value: id);

  Future<void> setToken(String token) =>
      _storage.write(key: _kToken, value: token);
  Future<void> setServerUrl(String url) =>
      _storage.write(key: _kServerUrl, value: url);

  Future<void> clear() => _storage.deleteAll();
}
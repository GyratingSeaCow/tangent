// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  static const _kToken = 'api_token';
  static const _kServerUrl = 'server_url';

  final FlutterSecureStorage _storage;

  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  Future<String?> getToken() => _storage.read(key: _kToken);
  Future<String?> getServerUrl() => _storage.read(key: _kServerUrl);

  Future<void> setToken(String token) =>
      _storage.write(key: _kToken, value: token);
  Future<void> setServerUrl(String url) =>
      _storage.write(key: _kServerUrl, value: url);

  Future<void> clear() => _storage.deleteAll();
}
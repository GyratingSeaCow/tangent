// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  static const _kToken = 'api_token';
  static const _kServerUrl = 'server_url';

  final FlutterSecureStorage _storage;

  SecureStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  SecureStore.forTesting({required FlutterSecureStorage storage})
      : _storage = storage;

  Future<String?> readToken() => _storage.read(key: _kToken);

  Future<void> writeToken(String token) =>
      _storage.write(key: _kToken, value: token);

  Future<String?> readServerUrl() => _storage.read(key: _kServerUrl);

  Future<void> writeServerUrl(String url) =>
      _storage.write(key: _kServerUrl, value: url);

  Future<void> clear() => _storage.deleteAll();
}
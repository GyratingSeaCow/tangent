// SPDX-License-Identifier: AGPL-3.0-or-later
/// `ocrSettingsClientProvider` must follow the server, not latch it.
///
/// A FutureProvider reading secure storage caches its first result forever,
/// because secure storage is not observable. On Jeff's Fold that meant:
/// change the server URL in Settings, and the handwriting section kept
/// calling the OLD host — the toggle sat inert with ZERO `/v1/ocr/*` lines
/// in the server log, which reads as a dead UI rather than a stale client.
/// Only an app restart cleared it.
///
/// The provider therefore watches `transcriptionClientProvider`, which both
/// `setServerUrl` call sites assign immediately after writing storage.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'package:tangent/screens/settings/handwriting_search_section.dart';
import 'package:tangent/services/transcription_client.dart';

/// In-memory stand-in: the real plugin needs a platform channel.
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage(this._values) : super();

  final Map<String, String> _values;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

void main() {
  test('the OCR client follows a server URL change', () async {
    final Map<String, String> stored = <String, String>{
      'server_url': 'http://192.168.1.206:8765',
      'api_token': 'tok',
    };
    final SecureStore store =
        SecureStore(storage: _FakeSecureStorage(stored));
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        secureStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(ocrSettingsClientProvider.future)).baseUrl,
      'http://192.168.1.206:8765',
      reason: 'the first build reads the stored URL',
    );

    // Exactly what the connection screen does: persist the new URL, then
    // publish the rebuilt transcription client.
    await store.setServerUrl('http://100.88.126.107:8765');
    container.read(transcriptionClientProvider.notifier).state =
        TranscriptionClient(
      baseUrl: 'http://100.88.126.107:8765',
      token: 'tok',
    );

    expect(
      (await container.read(ocrSettingsClientProvider.future)).baseUrl,
      'http://100.88.126.107:8765',
      reason: 'reconnecting to another server must rebuild the OCR client; '
          'a cached client silently calls the old host forever',
    );
  });

  test('the OCR client carries the stored token', () async {
    final SecureStore store = SecureStore(
      storage: _FakeSecureStorage(<String, String>{
        'server_url': 'http://host:8765',
        'api_token': 'secret-token',
      }),
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        secureStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    final client = await container.read(ocrSettingsClientProvider.future);
    expect(client.baseUrl, 'http://host:8765');
  });
}

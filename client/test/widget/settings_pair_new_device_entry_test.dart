// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings must offer "Pair a new device" wherever the server already
/// lives, and tapping it must land on the pending-codes screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/pair_pending.dart';
import 'package:tangent/screens/server/pair_new_device_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/transcription_client.dart';

class _FakeSecureStore implements SecureStore {
  @override
  Future<String?> getDeviceId() async => null;
  @override
  Future<void> setDeviceId(String id) async {}
  @override
  Future<String?> getServerUrl() async => null;
  @override
  Future<String?> getToken() async => null;
  @override
  Future<void> setServerUrl(String url) async {}
  @override
  Future<void> setToken(String token) async {}
  @override
  Future<void> clear() async {}
}

class _FakeClient extends TranscriptionClient {
  _FakeClient() : super(baseUrl: 'http://unused.invalid');

  @override
  Future<List<PairPendingEntry>> pairPending() async => <PairPendingEntry>[];
}

void main() {
  testWidgets('Settings has a Pair a new device row that opens the codes',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          secureStoreProvider.overrideWithValue(_FakeSecureStore()),
          transcriptionClientProvider.overrideWith((ref) => _FakeClient()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final Finder row =
        find.byKey(const ValueKey<String>('settings-pair-new-device'));
    await tester.scrollUntilVisible(row, 150);
    await tester.ensureVisible(row);
    await tester.pump();
    expect(row, findsOneWidget);

    await tester.tap(row);
    // Discrete pumps: the destination runs a poll timer, so pumpAndSettle
    // would never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byType(PairNewDeviceScreen), findsOneWidget);
  });
}

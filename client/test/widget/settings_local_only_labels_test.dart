// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Settings labels must state what actually happens. In particular the
// upload row must not be read as governing transcription: transcription to the
// self-hosted server runs on cellular regardless of these switches.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show secureStoreProvider;
import 'package:tangent/screens/settings/settings_screen.dart';

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

Future<void> _mount(WidgetTester tester, SettingsStore settings) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        secureStoreProvider.overrideWithValue(_FakeSecureStore()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('device-only recordings row reflects the stored value',
      (tester) async {
    await _mount(tester, SettingsStore(keepRecordingsOnDeviceOnly: true));

    final row = find.ancestor(
      of: find.text('Keep recordings on this device'),
      matching: find.byType(SwitchListTile),
    );
    await tester.scrollUntilVisible(row, 150);
    expect(tester.widget<SwitchListTile>(row).value, isTrue);
  });

  testWidgets('device-only row saves through the store', (tester) async {
    final settings = SettingsStore(keepRecordingsOnDeviceOnly: true);
    await _mount(tester, settings);

    final label = find.text('Keep recordings on this device');
    await tester.scrollUntilVisible(label, 150);
    await tester.tap(label);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(settings.keepRecordingsOnDeviceOnly, isFalse);
  });

  testWidgets('the upload switch never claims to govern transcription',
      (tester) async {
    await _mount(tester, SettingsStore());

    // The old label said "Wi-Fi only sync" with no mention that transcription
    // is exempt, which reads as "nothing reaches the network off Wi-Fi".
    expect(find.text('Wi-Fi only sync'), findsNothing);

    final upload = find.textContaining('Upload recordings only on Wi-Fi');
    await tester.scrollUntilVisible(upload, 150);
    expect(upload, findsOneWidget);

    // The honest part: transcription is called out as exempt.
    expect(
      find.textContaining(
        RegExp('transcription', caseSensitive: false),
        findRichText: true,
      ),
      findsWidgets,
    );
  });

  testWidgets('device-only subtitle says transcription still works',
      (tester) async {
    await _mount(tester, SettingsStore());

    final subtitle = find.textContaining(
      RegExp('transcri.*(mobile data|cellular)', caseSensitive: false),
    );
    await tester.scrollUntilVisible(subtitle, 150);
    expect(subtitle, findsWidgets);
  });
}

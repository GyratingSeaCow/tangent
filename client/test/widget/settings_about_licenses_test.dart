// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Settings footer and the Licenses page.
//
// The old footer hard-coded 'Tangent v1.0.0 — AGPL-3.0' — a stale literal
// that survived seven releases because nothing owned it. The rule now:
// the version shown in Settings comes from the BUILD (PackageInfo reads
// pubspec's version at build time), and licenses come from Flutter's
// LicenseRegistry (populated from the real bundled dependency set), so
// neither can drift from what actually shipped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
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

Future<void> _mount(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(SettingsStore()),
        secureStoreProvider.overrideWithValue(_FakeSecureStore()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Tangent',
      packageName: 'dev.tangent.tangent',
      version: '9.9.9',
      buildNumber: '99',
      buildSignature: '',
    );
  });

  testWidgets('footer shows the BUILD version, not a hard-coded one',
      (tester) async {
    await _mount(tester);
    final footer = find.text('Tangent v9.9.9 — AGPL-3.0');
    await tester.scrollUntilVisible(footer, 200);
    expect(footer, findsOneWidget);
  });

  testWidgets('a Licenses row opens the license page with Tangent as the '
      'application', (tester) async {
    await _mount(tester);
    final row = find.text('Licenses');
    await tester.scrollUntilVisible(row, 200);
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    // LicenseRegistry collection is async; pump a few frames.
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Tangent'), findsWidgets);
  });

  test('no source file carries a hard-coded app version string', () {
    // Regression guard for the literal that sat stale for seven releases.
    final List<String> offenders = <String>[];
    for (final FileSystemEntity f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.readAsStringSync().contains(RegExp(r'Tangent v\d+\.\d+\.\d+'))) {
        offenders.add(f.path.replaceAll('\\', '/'));
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'hard-coded version string (the v1.0.0 footer bug): $offenders',
    );
  });
}

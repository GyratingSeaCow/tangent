// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/home/welcome_pairing_dialog.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show secureStoreProvider, transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/screens/settings/welcome_message_section.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/widget_recording_coordinator.dart';

/// First-run welcome dialog (spec 2026-10-01): repeats the pairing
/// walkthrough at launch while NO server is paired, silenced forever by its
/// bottom-centre DO NOT REMIND ME AGAIN checkbox, re-armed by the Settings →
/// Server & devices "Show welcome message" toggle.

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Deterministic pairing state without the keystore plugin: the real
/// [SecureStore] hits flutter_secure_storage, which has no test host.
class _FakeSecureStore extends SecureStore {
  _FakeSecureStore({this.serverUrl});

  final String? serverUrl;

  @override
  Future<String?> getServerUrl() async => serverUrl;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalDb> mountHome(
    WidgetTester tester, {
    required SettingsStore settings,
    String? pairedUrl,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((_) => _StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(settings),
          secureStoreProvider.overrideWithValue(
            _FakeSecureStore(serverUrl: pairedUrl),
          ),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          deletionEligibilityProvider.overrideWith(
            (_) => Stream<Map<String, Eligibility>>.value(
              const <String, Eligibility>{},
            ),
          ),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  Future<void> unmountHome(WidgetTester tester, LocalDb db) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  testWidgets('unpaired launch with the pref on shows the welcome dialog',
      (tester) async {
    final LocalDb db = await mountHome(tester, settings: SettingsStore());

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsOneWidget);
    expect(find.text('Welcome to Tangent'), findsOneWidget);
    expect(find.text('DO NOT REMIND ME AGAIN'), findsOneWidget);
    // The walkthrough names the real steps, not a paraphrase.
    expect(find.textContaining('docker compose up -d'), findsOneWidget);
    expect(find.textContaining('code_issued'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('a paired device never sees the welcome dialog', (tester) async {
    final LocalDb db = await mountHome(
      tester,
      settings: SettingsStore(),
      pairedUrl: 'http://192.168.1.100:8765',
    );

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);

    await unmountHome(tester, db);
  });

  testWidgets('the pref off keeps the dialog away even when unpaired',
      (tester) async {
    final LocalDb db = await mountHome(
      tester,
      settings: SettingsStore(showWelcomeMessage: false),
    );

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);

    await unmountHome(tester, db);
  });

  testWidgets('Close dismisses for this launch without touching the pref',
      (tester) async {
    final SettingsStore settings = SettingsStore();
    final LocalDb db = await mountHome(tester, settings: settings);

    await tester.tap(find.byKey(WelcomePairingDialog.closeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);
    // Still armed: the reminder must repeat on the next launch.
    expect(settings.showWelcomeMessage, isTrue);

    await unmountHome(tester, db);
  });

  testWidgets(
      'checking DO NOT REMIND ME AGAIN persists the opt-out and closes',
      (tester) async {
    final SettingsStore settings = SettingsStore();
    final LocalDb db = await mountHome(tester, settings: settings);

    await tester.tap(find.byKey(WelcomePairingDialog.dismissForeverKey));
    await tester.pumpAndSettle();

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);
    expect(settings.showWelcomeMessage, isFalse);

    await unmountHome(tester, db);
  });

  testWidgets(
      'the settings toggle re-arms the welcome message after the opt-out',
      (tester) async {
    final SettingsStore settings =
        SettingsStore(showWelcomeMessage: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsStoreProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WelcomeMessageSection()),
        ),
      ),
    );

    final Finder toggle = find.byKey(WelcomeMessageSection.enabledKey);
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(settings.showWelcomeMessage, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// First-run welcome dialog (spec 2026-10-02): repeats the pairing
/// walkthrough on EVERY launch — paired or not — until the user checks
/// DO NOT REMIND ME AGAIN and hits Confirm. That is the ONLY way to remove
/// it: the checkbox alone does nothing permanent, Close is this-launch-only,
/// and the Settings → Server & devices "Show welcome message" toggle is
/// one-way — it can re-arm the message but flipping it off does not stick.

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
    Size size = const Size(1080, 2340),
  }) async {
    tester.view.physicalSize = size;
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

  Future<void> goToPage(WidgetTester tester, int page) async {
    while (find.byKey(WelcomePairingDialog.pageKey(page)).evaluate().isEmpty) {
      final Finder setUp = find.byKey(WelcomePairingDialog.setUpServerKey);
      await tester.tap(
        setUp.evaluate().isNotEmpty
            ? setUp
            : find.byKey(WelcomePairingDialog.nextKey),
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets('unpaired launch with no opt-out shows the welcome dialog', (
    tester,
  ) async {
    final LocalDb db = await mountHome(tester, settings: SettingsStore());

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsOneWidget);
    expect(find.text('Welcome to Tangent'), findsOneWidget);
    expect(
      find.text(
        'Tangent is your private recorder and notebook. Everything below '
        'already works, right now, fully offline:',
      ),
      findsOneWidget,
    );
    expect(find.text('✓ Record voice notes and meetings'), findsOneWidget);
    expect(
      find.text('✓ Notebooks with ink, text, images and PDFs'),
      findsOneWidget,
    );
    expect(find.text('✓ To-dos with a kanban board'), findsOneWidget);
    expect(find.text('Set up my server'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(find.byKey(WelcomePairingDialog.dismissForeverKey), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('all approved wizard copy is rendered verbatim', (tester) async {
    final LocalDb db = await mountHome(tester, settings: SettingsStore());

    for (final String text in <String>[
      'Welcome to Tangent',
      'Tangent is your private recorder and notebook. Everything below '
          'already works, right now, fully offline:',
      '✓ Record voice notes and meetings',
      '✓ Notebooks with ink, text, images and PDFs',
      '✓ To-dos with a kanban board',
      'Pairing with your own Tangent server (a free program you run on your '
          'PC) unlocks:',
      '+ Transcription — recordings become searchable text',
      '+ Sync — notebooks and to-dos on all your devices',
      'No account, no cloud — your data only ever touches hardware you own.',
      'Skip for now',
      'Set up my server',
      '1 of 4',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // The approved deck gives page 1 no location context: the pill must be a
    // bare "1 of 4" with no label beside it (Vera batch-E item 1).
    expect(find.text('Welcome'), findsNothing);

    await tester.tap(find.byKey(WelcomePairingDialog.setUpServerKey));
    await tester.pumpAndSettle();
    for (final String text in <String>[
      'Start the server',
      'On your PC',
      'On the PC that will host your server, open a terminal (PowerShell on '
          'Windows) inside the Tangent folder you downloaded, and run:',
      WelcomePairingDialog.startServerCommand,
      'What this does: starts the Tangent server inside Docker. It keeps '
          'running in the background and restarts with your PC — you only '
          'ever do this once.',
      'Needs Docker? Install Docker Desktop first — docker.com/get-started. '
          "Tangent's server is free and runs entirely on your machine.",
      'Back',
      'Next',
      '2 of 4',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }

    await tester.tap(find.byKey(WelcomePairingDialog.nextKey));
    await tester.pumpAndSettle();
    for (final String text in <String>[
      'Watch the server say hello',
      'On your PC',
      "In the same terminal, follow the server's log:",
      WelcomePairingDialog.serverLogCommand,
      "What you'll see: on its very first run the log prints a one-time setup "
          'command. Run that command once — it answers with an admin token. '
          'Save the token somewhere safe (a password manager is perfect): '
          "it's the master key for adding devices later.",
      "Done already? If you set this server up before, there's nothing to "
          're-run — just continue.',
      'Back',
      'Next',
      '3 of 4',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }

    await tester.tap(find.byKey(WelcomePairingDialog.nextKey));
    await tester.pumpAndSettle();
    for (final String text in <String>[
      'Pair this device',
      'On this device',
      'Open Settings → Server & devices → Find my server. Your PC appears '
          'automatically when both are on the same network — tap Pair next '
          'to it.',
      'The PC log shows a 6-digit code — type it here. The code lives for '
          '120 seconds; if it lapsed, read the log again for a fresh one:',
      WelcomePairingDialog.pairingLogCommand,
      'Why a code: it proves you control both machines, so nobody else on '
          'the network can attach to your server.',
      'You can always come back: this whole guide lives in Settings → Server '
          '& devices.',
      "DON'T SHOW THIS AGAIN",
      'Back',
      'Close',
      'Confirm',
      '4 of 4',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }

    await unmountHome(tester, db);
  });

  testWidgets('each page copies its exact command', (tester) async {
    final List<MethodCall> platformCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platformCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final LocalDb db = await mountHome(tester, settings: SettingsStore());

    await tester.tap(find.byKey(WelcomePairingDialog.setUpServerKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(WelcomePairingDialog.copyStartServerKey));
    await tester.pump();

    final Finder checkInDialog = find.descendant(
      of: find.byKey(WelcomePairingDialog.dialogKey),
      matching: find.byIcon(Icons.check),
    );
    expect(checkInDialog, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(checkInDialog, findsNothing);

    await tester.tap(find.byKey(WelcomePairingDialog.nextKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(WelcomePairingDialog.copyServerLogKey));
    await tester.pump();
    await tester.tap(find.byKey(WelcomePairingDialog.nextKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(WelcomePairingDialog.copyPairingLogKey));
    await tester.pump();

    final List<String?> copied = platformCalls
        .where((MethodCall call) => call.method == 'Clipboard.setData')
        .map(
          (MethodCall call) =>
              (call.arguments as Map<Object?, Object?>)['text'] as String?,
        )
        .toList();
    expect(copied, <String>[
      WelcomePairingDialog.startServerCommand,
      WelcomePairingDialog.serverLogCommand,
      WelcomePairingDialog.pairingLogCommand,
    ]);

    await unmountHome(tester, db);
  });

  testWidgets('navigation advances 1 → 2 → 3 → 4 and Back returns to 3', (
    tester,
  ) async {
    final LocalDb db = await mountHome(tester, settings: SettingsStore());

    expect(find.byKey(WelcomePairingDialog.pageKey(1)), findsOneWidget);
    await tester.tap(find.byKey(WelcomePairingDialog.setUpServerKey));
    await tester.pumpAndSettle();
    expect(find.byKey(WelcomePairingDialog.pageKey(2)), findsOneWidget);
    await tester.tap(find.byKey(WelcomePairingDialog.nextKey));
    await tester.pumpAndSettle();
    expect(find.byKey(WelcomePairingDialog.pageKey(3)), findsOneWidget);
    await tester.tap(find.byKey(WelcomePairingDialog.nextKey));
    await tester.pumpAndSettle();
    expect(find.byKey(WelcomePairingDialog.pageKey(4)), findsOneWidget);
    await tester.tap(find.byKey(WelcomePairingDialog.backKey));
    await tester.pumpAndSettle();
    expect(find.byKey(WelcomePairingDialog.pageKey(3)), findsOneWidget);

    await unmountHome(tester, db);
  });

  testWidgets('arrow keys navigate and the wizard fits a small viewport', (
    tester,
  ) async {
    final LocalDb db = await mountHome(
      tester,
      settings: SettingsStore(),
      size: const Size(360, 640),
    );
    expect(tester.takeException(), isNull, reason: 'page 1');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.byKey(WelcomePairingDialog.pageKey(2)), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'page 2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'page 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.byKey(WelcomePairingDialog.pageKey(4)), findsOneWidget);
    expect(find.byKey(WelcomePairingDialog.dismissForeverKey), findsOneWidget);
    expect(find.byKey(WelcomePairingDialog.confirmKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('Skip for now dismisses without persisting', (tester) async {
    final SettingsStore settings = SettingsStore();
    final LocalDb db = await mountHome(tester, settings: settings);

    await tester.tap(find.byKey(WelcomePairingDialog.closeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);
    expect(settings.showWelcomeMessage, isTrue);

    await unmountHome(tester, db);
  });

  testWidgets('a PAIRED device still sees the welcome dialog at launch', (
    tester,
  ) async {
    final LocalDb db = await mountHome(
      tester,
      settings: SettingsStore(),
      pairedUrl: 'http://192.168.1.100:8765',
    );

    // Spec 2026-10-02: pairing does NOT silence the reminder. Only the
    // checkbox + Confirm does.
    expect(find.byKey(WelcomePairingDialog.dialogKey), findsOneWidget);

    await unmountHome(tester, db);
  });

  testWidgets('the persisted opt-out keeps the dialog away', (tester) async {
    final LocalDb db = await mountHome(
      tester,
      settings: SettingsStore(showWelcomeMessage: false),
    );

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);

    await unmountHome(tester, db);
  });

  testWidgets('Close dismisses for this launch without touching the pref', (
    tester,
  ) async {
    final SettingsStore settings = SettingsStore();
    final LocalDb db = await mountHome(tester, settings: settings);

    await goToPage(tester, 4);
    await tester.tap(find.byKey(WelcomePairingDialog.closeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);
    // Still armed: the reminder must repeat on the next launch.
    expect(settings.showWelcomeMessage, isTrue);

    await unmountHome(tester, db);
  });

  testWidgets(
    'checking the box alone neither closes the dialog nor persists anything',
    (tester) async {
      final SettingsStore settings = SettingsStore();
      final LocalDb db = await mountHome(tester, settings: settings);

      await goToPage(tester, 4);
      await tester.tap(find.byKey(WelcomePairingDialog.dismissForeverKey));
      await tester.pumpAndSettle();

      // The checkbox is only half of the contract — the dialog stays up and
      // the pref is untouched until Confirm is pressed.
      expect(find.byKey(WelcomePairingDialog.dialogKey), findsOneWidget);
      expect(settings.showWelcomeMessage, isTrue);

      await unmountHome(tester, db);
    },
  );

  testWidgets('Confirm is disabled until the box is checked', (tester) async {
    final LocalDb db = await mountHome(tester, settings: SettingsStore());

    await goToPage(tester, 4);
    final Finder confirm = find.byKey(WelcomePairingDialog.confirmKey);
    expect(confirm, findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(WelcomePairingDialog.dismissForeverKey));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await unmountHome(tester, db);
  });

  testWidgets(
    'checkbox + Confirm — the ONLY removal path — persists the opt-out '
    'and closes',
    (tester) async {
      final SettingsStore settings = SettingsStore();
      final LocalDb db = await mountHome(tester, settings: settings);

      await goToPage(tester, 4);
      await tester.tap(find.byKey(WelcomePairingDialog.dismissForeverKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WelcomePairingDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(find.byKey(WelcomePairingDialog.dialogKey), findsNothing);
      expect(settings.showWelcomeMessage, isFalse);

      await unmountHome(tester, db);
    },
  );

  testWidgets(
    'the settings toggle re-arms the welcome message after the opt-out',
    (tester) async {
      final SettingsStore settings = SettingsStore(showWelcomeMessage: false);
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
    },
  );

  testWidgets(
    'the settings toggle is one-way: flipping it OFF does not stick',
    (tester) async {
      final SettingsStore settings = SettingsStore();
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
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // Spec 2026-10-02: the ONLY way to remove the welcome message is the
      // dialog's checkbox + Confirm. The switch snaps back on.
      expect(settings.showWelcomeMessage, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    },
  );
}

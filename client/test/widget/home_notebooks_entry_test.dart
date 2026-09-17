// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/notebook/notebook_list_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/fake_notebook_repository.dart';
import '../support/widget_recording_coordinator.dart';

/// T4 (home side): the app bar gains a Notebooks entry point that opens the
/// notebook LIST, sitting between the dumps list and settings and leaving the
/// existing sync / dumps / settings plumbing untouched.

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookRepository notebooks;

  Future<LocalDb> mountHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    notebooks = FakeNotebookRepository();
    addTearDown(notebooks.dispose);
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
          storageBootstrapProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          deletionEligibilityProvider.overrideWith(
            (_) => Stream<Map<String, Eligibility>>.value(
              const <String, Eligibility>{},
            ),
          ),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
          notebookRepositoryProvider.overrideWithValue(notebooks),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    return db;
  }

  Future<void> unmountHome(WidgetTester tester, LocalDb db) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  testWidgets(
      'app bar exposes a Notebooks action between dumps and settings',
      (tester) async {
    final LocalDb db = await mountHome(tester);

    expect(find.byIcon(Icons.menu_book), findsOneWidget);
    expect(
      tester
          .widgetList<IconButton>(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byType(IconButton),
            ),
          )
          .map((IconButton button) => button.tooltip)
          .toList(),
      <String>['Sync now', 'View dumps', 'Notebooks', 'Settings'],
    );
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('tapping Notebooks pushes the notebook list', (tester) async {
    final LocalDb db = await mountHome(tester);

    await tester.tap(find.byIcon(Icons.menu_book));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NotebookListScreen), findsOneWidget);
    expect(find.text('Notebooks'), findsWidgets);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('opening Notebooks never disturbs the dumps entry point',
      (tester) async {
    final LocalDb db = await mountHome(tester);

    await tester.tap(find.byIcon(Icons.menu_book));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.byType(NotebookListScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.list), findsOneWidget);
    expect(find.byIcon(Icons.cloud_sync), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(notebooks.createCalls, 0);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });
}

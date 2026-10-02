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
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/screens/notebook/notebook_list_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show SettingsScreen, settingsStoreProvider;
import 'package:tangent/screens/todo/todo_list_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/widgets/instrument_scaffold.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

import '../support/fake_notebook_repository.dart';
import '../support/widget_recording_coordinator.dart';

/// Instrument Console v2 chrome: the top rail is a jump bar present on the
/// Capture screen, the active destination is lit and inert, and the global
/// lime FAB's create sheet routes every kind through its EXISTING flow.

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
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          // Welcome dialog (spec 2026-10-02) is launch-global; keep it out
          // of tests that are not about it.
          settingsStoreProvider.overrideWithValue(
            SettingsStore(showWelcomeMessage: false),
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('top nav rail', () {
    testWidgets('shows all six destinations with Capture active',
        (tester) async {
      final LocalDb db = await mountHome(tester);

      expect(find.byType(TopNavRail), findsOneWidget);
      final List<String?> tooltips = tester
          .widgetList<IconButton>(
            find.descendant(
              of: find.byType(TopNavRail),
              matching: find.byType(IconButton),
            ),
          )
          .map((IconButton b) => b.tooltip)
          .toList();
      expect(
        tooltips,
        <String>[
          'Capture',
          'Recordings',
          'Notebooks',
          'To Do',
          'Ask',
          'Settings',
        ],
      );
      // The active destination is lit but inert.
      final IconButton capture = tester.widgetList<IconButton>(
        find.descendant(
          of: find.byType(TopNavRail),
          matching: find.byType(IconButton),
        ),
      ).first;
      expect(capture.onPressed, isNull);
      expect(tester.takeException(), isNull);

      await unmountHome(tester, db);
    });

    testWidgets('rail jumps to Recordings, Notebooks, To Do and Settings',
        (tester) async {
      final LocalDb db = await mountHome(tester);

      Future<void> popHome(Type pushed) async {
        Navigator.of(tester.element(find.byType(pushed))).pop();
        await settle(tester);
        expect(find.byType(HomeScreen), findsOneWidget);
      }

      // Pushed screens adopt the rail in the list-restyle phase; here the
      // rail's jump contract is proven from the Capture root.
      await tester.tap(find.byIcon(Icons.list));
      await settle(tester);
      expect(find.byType(DumpsListScreen), findsOneWidget);
      await popHome(DumpsListScreen);

      await tester.tap(find.byIcon(Icons.menu_book));
      await settle(tester);
      expect(find.byType(NotebookListScreen), findsOneWidget);
      await popHome(NotebookListScreen);

      await tester.tap(find.byIcon(Icons.check_box));
      await settle(tester);
      expect(find.byType(TodoListScreen), findsOneWidget);
      await popHome(TodoListScreen);

      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await popHome(SettingsScreen);
      expect(tester.takeException(), isNull);

      await unmountHome(tester, db);
    });

    testWidgets(
        'jumping list-to-list never shows Capture in between (one atomic '
        'navigator transaction)', (tester) async {
      final LocalDb db = await mountHome(tester);

      await tester.tap(find.byKey(railKey(TangentRoot.todo)));
      await settle(tester);
      expect(find.byType(TodoListScreen), findsOneWidget);

      // Tap the rail ON the To Do screen and pump ONE frame at a time: at no
      // point may Capture be the visible top-of-stack. Before the fix,
      // popUntil(root) landed Home for a frame, then push animated the
      // next list in — the "flash back to Home" seen on-device.
      await tester.tap(find.byKey(railKey(TangentRoot.notebooks)).last);
      await tester.pump();
      // Mid-transition (the page route animates for 300ms): the screen we
      // left must STILL be mounted beneath the incoming one, and the
      // navigator must hold exactly [root, To Do, Notebooks] — never a bare
      // [root, Notebooks] with Home showing through. With popUntil+push the
      // To Do route was torn out before the push animated.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NotebookListScreen), findsOneWidget);
      expect(
        find.byType(TodoListScreen),
        findsOneWidget,
        reason: 'the exiting list must stay beneath the transition',
      );
      final ModalRoute<dynamic>? todoRoute = ModalRoute.of(
        tester.element(find.byType(TodoListScreen)),
      );
      expect(todoRoute, isNotNull);
      // The discriminator: a popped route animates OUT (reverse) and Home
      // shows through beneath it; a route removed by pushAndRemoveUntil
      // sits still (completed) under the incoming page until it is
      // disposed after the transition.
      expect(
        todoRoute!.animation!.status,
        AnimationStatus.completed,
        reason: 'popUntil would be animating To Do OUT (reverse)',
      );
      await settle(tester);
      expect(find.byType(NotebookListScreen), findsOneWidget);
      expect(find.byType(TodoListScreen), findsNothing);
      // The stack is still root + destination: back walks out through Capture.
      Navigator.of(tester.element(find.byType(NotebookListScreen))).pop();
      await settle(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      await unmountHome(tester, db);
    });
  });

  group('global create FAB', () {
    testWidgets('opens the create sheet with all five kinds', (tester) async {
      final LocalDb db = await mountHome(tester);

      await tester.tap(find.byKey(InstrumentScaffold.createFabKey));
      await settle(tester);

      expect(find.byKey(const Key('create-sheet-recording')), findsOneWidget);
      expect(find.byKey(const Key('create-sheet-meeting')), findsOneWidget);
      expect(find.byKey(const Key('create-sheet-text-note')), findsOneWidget);
      expect(find.byKey(const Key('create-sheet-notebook')), findsOneWidget);
      expect(find.byKey(const Key('create-sheet-todo')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await unmountHome(tester, db);
    });

    testWidgets('Recording starts a capture through the existing controller',
        (tester) async {
      final LocalDb db = await mountHome(tester);

      await tester.tap(find.byKey(InstrumentScaffold.createFabKey));
      await settle(tester);
      await tester.tap(find.byKey(const Key('create-sheet-recording')));
      await settle(tester);

      // The same stop affordance a record-button tap produces.
      expect(find.byIcon(Icons.stop), findsOneWidget);

      // Stop so teardown never kills a live fake capture.
      await tester.tap(find.byKey(HomeScreen.recordButtonKey));
      await settle(tester);
      await unmountHome(tester, db);
    });

    testWidgets('Notebook creates through the repository and opens the editor',
        (tester) async {
      final LocalDb db = await mountHome(tester);

      await tester.tap(find.byKey(InstrumentScaffold.createFabKey));
      await settle(tester);
      await tester.tap(find.byKey(const Key('create-sheet-notebook')));
      await settle(tester);

      expect(notebooks.createCalls, 1);
      expect(find.byType(NotebookEditorScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      await unmountHome(tester, db);
    });

    testWidgets('To-do lands on the list with quick-add focused',
        (tester) async {
      final LocalDb db = await mountHome(tester);

      await tester.tap(find.byKey(InstrumentScaffold.createFabKey));
      await settle(tester);
      await tester.tap(find.byKey(const Key('create-sheet-todo')));
      await settle(tester);

      expect(find.byType(TodoListScreen), findsOneWidget);
      final TextField field = tester.widget<TextField>(
        find.byKey(TodoListScreen.quickAddFieldKey),
      );
      expect(field.focusNode?.hasFocus, isTrue);
      expect(tester.takeException(), isNull);

      await unmountHome(tester, db);
    });
  });
}

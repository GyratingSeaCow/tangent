// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/note/note_compose_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/transcription_client.dart';
import '../support/widget_recording_coordinator.dart';

/// T2 (home side): the home screen consumes the [DumpsCreateAction] popped by
/// the dumps list FAB — switching its mode selector and either opening note
/// compose (text note) or starting a recording immediately (voice modes).

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Reuses the widget coordinator seam but records every mode passed to
/// [start] so tests can prove which wire mode the FAB result triggered.
class _ModeRecordingCoordinator extends WidgetRecordingCoordinator {
  _ModeRecordingCoordinator(super.recorder);
  final List<String> startedModes = [];

  @override
  Future<Outcome<CaptureReservation>> start({required String mode}) {
    startedModes.add(mode);
    return super.start(mode: mode);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StubRecordingService stub;
  late _ModeRecordingCoordinator coordinator;

  Future<LocalDb> mountHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = LocalDb.forTesting(NativeDatabase.memory());
    stub = StubRecordingService();
    coordinator = _ModeRecordingCoordinator(stub);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((ref) => _StubClient()),
          recordingServiceProvider.overrideWithValue(stub),
          recordingCoordinatorProvider.overrideWith((ref) => coordinator),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          // Keep the pushed dumps list off the real DB watch/fake clock.
          deletionEligibilityProvider.overrideWith(
            (_) => Stream.value(const <String, Eligibility>{}),
          ),
          dumpsProvider.overrideWith((_) => Stream.value(const <DumpRow>[])),
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

  /// Opens the dumps list from the app bar and settles the push transition.
  Future<void> openDumps(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.list));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(DumpsListScreen), findsOneWidget);
  }

  Set<DumpMode> selectedModes(WidgetTester tester) => tester
      .widget<SegmentedButton<DumpMode>>(find.byType(SegmentedButton<DumpMode>))
      .selected;

  testWidgets(
      'DumpsCreateAction.textNote result switches home to Text Note and '
      'opens compose without touching the recorder', (tester) async {
    EditableText.debugDeterministicCursor = true;
    addTearDown(() => EditableText.debugDeterministicCursor = false);
    final db = await mountHome(tester);

    await openDumps(tester);
    // Filters are dropdowns now: open the menu, then tap the same key.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-filter-textNote')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(FloatingActionButton));
    // Pop back to home, then the compose push (autofocused field: bounded
    // pumps, no pumpAndSettle).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(NoteComposeScreen), findsOneWidget);
    expect(
      stub.events,
      isEmpty,
      reason: 'a text-note action must never reach the recorder',
    );
    expect(coordinator.startedModes, isEmpty);

    // Home behind the compose route now shows Text Note selected.
    Navigator.of(tester.element(find.byType(NoteComposeScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(selectedModes(tester), {DumpMode.textNote});
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets(
      'DumpsCreateAction.brainDump result starts recording immediately with '
      'mode brain_dump', (tester) async {
    final db = await mountHome(tester);

    await openDumps(tester);
    // Filters are dropdowns now: open the menu, then tap the same key.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-filter-brainDump')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(DumpsListScreen), findsNothing);
    expect(stub.events, contains('start'));
    expect(coordinator.startedModes, ['brain_dump']);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(selectedModes(tester), {DumpMode.brainDump});
    expect(find.byType(NoteComposeScreen), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets(
      'DumpsCreateAction.meeting result starts recording immediately with '
      'mode meeting', (tester) async {
    final db = await mountHome(tester);

    await openDumps(tester);
    // Filters are dropdowns now: open the menu, then tap the same key.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mode-filter-meeting')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(stub.events, contains('start'));
    expect(coordinator.startedModes, ['meeting']);
    expect(selectedModes(tester), {DumpMode.meeting});
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('backing out of the dumps list without the FAB changes nothing',
      (tester) async {
    final db = await mountHome(tester);

    await openDumps(tester);
    Navigator.of(tester.element(find.byType(DumpsListScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(stub.events, isEmpty);
    expect(coordinator.startedModes, isEmpty);
    expect(find.byType(NoteComposeScreen), findsNothing);
    expect(selectedModes(tester), {DumpMode.brainDump});
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });
}
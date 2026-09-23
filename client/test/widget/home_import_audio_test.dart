// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/audio_file_picker.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/widget_recording_coordinator.dart';

/// Jeff: "There also needs to be an Import Audio button which will allow you
/// to import audio into the tangent folder by copying it to the tangent
/// folder and then processing it". He placed it on the home screen next to
/// the record button.

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Records what the user picked, so the test can drive cancel vs choose.
class _FakePicker implements AudioFilePicker {
  _FakePicker(this._result);

  final PickedAudio? _result;
  int calls = 0;

  @override
  Future<List<PickedAudio>> pickMultiple() async =>
      throw UnimplementedError('home screen never bulk-imports');

  @override
  Future<PickedAudio?> pick() async {
    calls++;
    return _result;
  }
}

class _RecordingImport implements AudioImportRunner {
  final List<String> imported = <String>[];
  Outcome<String> result = const Ok<String>('dump-1');

  @override
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  }) async {
    imported.add(sourcePath);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalDb> mountHome(
    WidgetTester tester, {
    required AudioFilePicker picker,
    required AudioImportRunner importer,
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
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          audioFilePickerProvider.overrideWithValue(picker),
          audioImportRunnerProvider.overrideWithValue(importer),
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

  testWidgets('the home screen offers an Import audio action', (tester) async {
    final _FakePicker picker = _FakePicker(null);
    final _RecordingImport importer = _RecordingImport();
    final LocalDb db =
        await mountHome(tester, picker: picker, importer: importer);

    expect(
      find.byKey(const ValueKey('home-import-audio')),
      findsOneWidget,
      reason: 'import audio must be reachable from the home screen',
    );

    await unmountHome(tester, db);
  });

  testWidgets('picking a file imports it', (tester) async {
    final _FakePicker picker = _FakePicker(
      const PickedAudio(path: '/tmp/meeting.m4a', name: 'meeting.m4a'),
    );
    final _RecordingImport importer = _RecordingImport();
    final LocalDb db =
        await mountHome(tester, picker: picker, importer: importer);

    await tester.tap(find.byKey(const ValueKey('home-import-audio')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1, reason: 'tapping must open the file picker');
    expect(
      importer.imported,
      <String>['/tmp/meeting.m4a'],
      reason: 'the chosen file must be imported',
    );

    await unmountHome(tester, db);
  });

  testWidgets('cancelling the picker imports nothing', (tester) async {
    final _FakePicker picker = _FakePicker(null);
    final _RecordingImport importer = _RecordingImport();
    final LocalDb db =
        await mountHome(tester, picker: picker, importer: importer);

    await tester.tap(find.byKey(const ValueKey('home-import-audio')));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(
      importer.imported,
      isEmpty,
      reason: 'a cancelled pick must not import anything',
    );

    await unmountHome(tester, db);
  });

  testWidgets('a failed import tells the user instead of failing silently',
      (tester) async {
    final _FakePicker picker = _FakePicker(
      const PickedAudio(path: '/tmp/broken.m4a', name: 'broken.m4a'),
    );
    final _RecordingImport importer = _RecordingImport()
      ..result = const Fail<String>(
        (code: ProblemCode.invalid, message: 'That file is empty'),
      );
    final LocalDb db =
        await mountHome(tester, picker: picker, importer: importer);

    await tester.tap(find.byKey(const ValueKey('home-import-audio')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('That file is empty'),
      findsOneWidget,
      reason: 'an import failure must be surfaced, not swallowed',
    );

    await unmountHome(tester, db);
  });

  testWidgets('import is unavailable while recording', (tester) async {
    final _FakePicker picker = _FakePicker(null);
    final _RecordingImport importer = _RecordingImport();
    final LocalDb db =
        await mountHome(tester, picker: picker, importer: importer);

    // Start a recording: importing mid-capture would contend for the very
    // reservation machinery the capture is using.
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();

    final Widget button = tester.widget(
      find.byKey(const ValueKey('home-import-audio')),
    );
    expect(
      (button as dynamic).onPressed,
      isNull,
      reason: 'import must be disabled while a recording is active',
    );

    await unmountHome(tester, db);
  });
}

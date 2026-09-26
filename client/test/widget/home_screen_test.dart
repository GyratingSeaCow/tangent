// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import '../support/widget_recording_coordinator.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/recording_importer.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/main.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/note/note_compose_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/recording/recording_waveform.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';
import '../support/resolved_temp.dart';

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

class _StorageRecoveryClient extends TranscriptionClient {
  _StorageRecoveryClient(this.db) : super(baseUrl: 'http://test');

  final LocalDb db;
  int getJobCalls = 0;
  DumpRow? rowWhenRecoveryStarted;
  Completer<TranscriptionJobSnapshot>? _pendingGet;

  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async {
    rowWhenRecoveryStarted = await db.getDump('import-recovery');
    getJobCalls += 1;
    final pending = Completer<TranscriptionJobSnapshot>();
    _pendingGet = pending;
    return pending.future;
  }

  void completeRecovery() {
    final pending = _pendingGet;
    if (pending == null || pending.isCompleted) return;
    pending.complete(
      const TranscriptionJobSnapshot(
        id: 'job-import',
        requestId: 'request-import',
        dumpId: 'import-recovery',
        status: 'completed',
        model: 'large-v3',
        transcript: 'recovered immediately after import',
      ),
    );
  }
}

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _CountingServerTranscriptionService extends ServerTranscriptionService {
  _CountingServerTranscriptionService({
    required super.db,
    required super.recordingAccess,
    required super.mutations,
  }) : super(
          client: _StubClient(),
        );

  int reconcileCalls = 0;

  @override
  Future<void> reconcilePending() async {
    reconcileCalls += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TangentApp reconciles transcriptions on startup and resume',
      (tester) async {
    final temp = createResolvedTempSync('tangent-lifecycle-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    // Open real SQLite outside the widget fake clock before its watch starts.
    await tester.runAsync(() => db.getDump('startup-empty'));
    final service = _CountingServerTranscriptionService(
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith((ref) =>
              WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
        ],
        child: const TangentApp(),
      ),
    );
    await tester.pump();

    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(service.reconcileCalls, 2);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(TangentApp)));
    expect(container.exists(transcriptionRecoveryOwnerProvider), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.reconcileCalls, 2);

    var closed = false;
    await tester.runAsync(() async {
      unawaited(
        bound.mutations.drain().then((_) => db.close()).then((_) {
          closed = true;
        }),
      );
    });
    final closeDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (!closed && DateTime.now().isBefore(closeDeadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      closed,
      isTrue,
      reason: 'drain the real DB watch across the widget clock',
    );
    temp.deleteSync(recursive: true);
  });

  testWidgets('lifecycle reconciliation contains recovery query failures',
      (tester) async {
    final temp =
        createResolvedTempSync('tangent-lifecycle-error-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    await db.close();
    final service = ServerTranscriptionService(
      client: _StubClient(),
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith((ref) =>
              WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
        ],
        child: const TangentApp(),
      ),
    );
    await tester.pump();

    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    temp.deleteSync(recursive: true);
  });

  testWidgets(
      'startup imports rows and starts recovery without blocking library',
      (tester) async {
    final temp = createResolvedTempSync('tangent-storage-ready-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final backend = FilesystemStorageBackend();
    final bound = await createBoundServiceFixture(db,
        backend: backend, registerDrain: false,);
    final catalog = SqliteStorageCatalog(
      db: db,
      backend: backend,
      mutations: bound.mutations,
      stagingDirectory: storage.stagingDir.path,
      idFactory: () => 'fixture-location',
      now: () => DateTime.utc(2026, 9, 15),
      canChooseDefault: false,
    );
    final importer = BoundRecordingImporter(
      db: db,
      backend: backend,
      mutations: bound.mutations,
    );
    final deletion = DefaultLocalDeletionService(
      db: db,
      backend: backend,
      mutations: bound.mutations,
    );
    final client = _StorageRecoveryClient(db);
    addTearDown(() async {
      client.completeRecovery();
      await disposeBoundWidget(tester, bound);
      await tester.runAsync(db.close);
      temp.deleteSync(recursive: true);
    });
    storage.pathFor('import-recovery').writeAsBytesSync([1, 2, 3]);
    storage.metaPathFor('import-recovery').writeAsStringSync(
          jsonEncode({
            'schemaVersion': 2,
            'id': 'import-recovery',
            'createdAt': DateTime.utc(2026, 9, 15).toIso8601String(),
            'updatedAt': DateTime.utc(2026, 9, 15).toIso8601String(),
            'mode': 'brain_dump',
            'durationSeconds': 5,
            'title': 'Imported recovery',
            'transcriptionStatus': 'running',
            'transcriptionRequestId': 'request-import',
            'transcriptionJobId': 'job-import',
            'transcriptionAttempt': 1,
          }),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          storageAudioStorageProvider.overrideWithValue(storage),
          storageBackendProvider.overrideWithValue(backend),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          storageCatalogProvider.overrideWithValue(catalog),
          recordingImporterProvider.overrideWithValue(importer),
          localDeletionServiceProvider.overrideWithValue(deletion),
          transcriptionClientProvider.overrideWith((ref) => client),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
        ],
        child: const TangentApp(),
      ),
    );
    await tester.pump();
    expect(find.text('Tangent'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    await pumpBoundUntil(tester, () => client.getJobCalls > 0);

    expect(client.rowWhenRecoveryStarted?.id, 'import-recovery');
    expect(client.rowWhenRecoveryStarted?.transcriptionStatus, 'running');

    client.completeRecovery();
    await pumpBoundUntil(tester, () async {
      final recovered = await db.getDump('import-recovery');
      return recovered?.transcriptionStatus == 'completed' &&
          recovered?.transcriptionError == null;
    });

    final recovered = (await db.getDump('import-recovery'))!;
    expect(recovered.transcript, 'recovered immediately after import');
    expect(recovered.transcriptionRequestId, 'request-import');
    expect(recovered.transcriptionJobId, 'job-import');
    expect(recovered.transcriptionAttempt, 1);

    await disposeBoundWidget(tester, bound);
  });

  testWidgets('Home screen renders title and record button', (tester) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((ref) => _StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('Tangent'), findsOneWidget);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('Home screen has sync, dumps, and settings buttons',
      (tester) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((ref) => _StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.byIcon(Icons.cloud_sync), findsOneWidget);
    expect(find.byIcon(Icons.list), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('waveform appears only while recording without target overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = LocalDb.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((ref) => _StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.byType(RecordingWaveform), findsNothing);
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(find.byType(RecordingWaveform), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  // ---------------------------------------------------------------------
  // Task 8: Text Note mode — third segment and compose entry.
  // ---------------------------------------------------------------------

  /// Mounts the home screen at the target handset viewport (1080x2340 @3x)
  /// with the standard stub overrides. Returns the db for teardown.
  Future<LocalDb> mountHome(
    WidgetTester tester, {
    StubRecordingService? recorder,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final service = recorder ?? StubRecordingService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((ref) => _StubClient()),
          recordingServiceProvider.overrideWithValue(service),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    return db;
  }

  /// Unmount the tree, flush any stream-close timers, then close the db
  /// (same teardown ordering as note_compose_test.dart).
  Future<void> unmountHome(WidgetTester tester, LocalDb db) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  testWidgets('mode selector renders Brain Dump, Meeting, and Text Note',
      (tester) async {
    final db = await mountHome(tester);

    expect(find.text('Brain Dump'), findsOneWidget);
    expect(find.text('Meeting'), findsOneWidget);
    expect(find.text('Text Note'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets(
      'Text Note mode swaps the center button to edit_note with Tap to write '
      'and hides the audio-only timer', (tester) async {
    final db = await mountHome(tester);

    // Audio default: mic, record caption, timer.
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.text('Text Note'));
    await tester.pump();

    expect(find.byIcon(Icons.edit_note), findsOneWidget);
    expect(find.text('Tap to write'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.text('Tap to record'), findsNothing);
    expect(
      find.text('00:00'),
      findsNothing,
      reason: 'the recording timer is an audio-mode affordance',
    );
    expect(find.byType(RecordingWaveform), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets(
      'tapping the center button in Text Note mode pushes compose and never '
      'touches the recording state machine', (tester) async {
    EditableText.debugDeterministicCursor = true;
    addTearDown(() => EditableText.debugDeterministicCursor = false);
    final stub = StubRecordingService();
    final db = await mountHome(tester, recorder: stub);

    await tester.tap(find.text('Text Note'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.edit_note));
    // Bounded pumps: let the route transition finish without pumpAndSettle
    // (the compose screen autofocuses a text field).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(NoteComposeScreen), findsOneWidget);
    expect(
      stub.events,
      isEmpty,
      reason: 'controller.start must be unreachable in Text Note mode',
    );
    expect(find.byType(RecordingWaveform), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('Brain Dump still starts recording after visiting Text Note',
      (tester) async {
    final stub = StubRecordingService();
    final db = await mountHome(tester, recorder: stub);

    await tester.tap(find.text('Text Note'));
    await tester.pump();
    await tester.tap(find.text('Brain Dump'));
    await tester.pump();

    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();

    expect(stub.events, contains('start'));
    expect(find.byType(RecordingWaveform), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byType(NoteComposeScreen), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });
}

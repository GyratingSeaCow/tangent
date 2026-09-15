// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/main.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/recording/recording_waveform.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

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
    _pendingGet!.complete(
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
    required super.audioStorage,
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
    final temp = Directory.systemTemp.createTempSync('tangent-lifecycle-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final service = _CountingServerTranscriptionService(
      db: db,
      audioStorage: AudioStorage.test(temp),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
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

    await tester.pumpWidget(const SizedBox.shrink());
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.reconcileCalls, 2);

    await db.close();
    temp.deleteSync(recursive: true);
  });

  testWidgets('lifecycle reconciliation contains recovery query failures',
      (tester) async {
    final temp =
        Directory.systemTemp.createTempSync('tangent-lifecycle-error-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    await db.close();
    final service = ServerTranscriptionService(
      client: _StubClient(),
      db: db,
      audioStorage: AudioStorage.test(temp),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
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
      'storage access imports rows then starts recovery without blocking readiness',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-storage-ready-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final client = _StorageRecoveryClient(db);
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
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => client),
          storageReadyProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(home: StorageSetupScreen()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StorageSetupScreen)),
    );
    final chooseButton = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );

    await tester.runAsync(() async {
      chooseButton.onPressed!();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (client.getJobCalls == 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('storage readiness did not start transcription recovery');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pump();

    expect(client.rowWhenRecoveryStarted?.id, 'import-recovery');
    expect(client.rowWhenRecoveryStarted?.transcriptionStatus, 'running');
    expect(container.read(storageReadyProvider), isTrue);
    expect(find.text('Choose folder'), findsOneWidget);
    expect(find.text('Opening…'), findsNothing);

    await tester.runAsync(() async {
      client.completeRecovery();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (true) {
        final recovered = await db.getDump('import-recovery');
        if (recovered?.transcriptionStatus == 'completed' &&
            recovered?.transcriptionError == null) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('imported durable row did not finish recovery');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });

    final recovered = (await db.getDump('import-recovery'))!;
    expect(recovered.transcript, 'recovered immediately after import');
    expect(recovered.transcriptionRequestId, 'request-import');
    expect(recovered.transcriptionJobId, 'job-import');
    expect(recovered.transcriptionAttempt, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
    temp.deleteSync(recursive: true);
  });

  testWidgets('Home screen renders title and record button', (tester) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((ref) => _StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
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
}

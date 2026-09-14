// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/services/local_transcription_coordinator.dart';
import 'package:tangent/services/on_device_transcription.dart';
import 'package:tangent/services/recording_playback.dart';

void main() {
  testWidgets('Transcribe stores local result without a network client',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-detail-local-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final coordinator = LocalTranscriptionCoordinator(
      service: _FakeLocalService(),
      db: db,
      audioStorage: storage,
    );
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = DumpRow(
      id: 'local-1',
      createdAt: DateTime.utc(2026, 9, 13),
      updatedAt: DateTime.utc(2026, 9, 13),
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Local recording',
      audioPath: storage.pathFor('local-1').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
    );
    await db.upsertDump(row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          localTranscriptionCoordinatorProvider.overrideWith(
            (ref) => coordinator,
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: const MaterialApp(
          home: DumpDetailScreen(
            dumpId: 'local-1',
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final transcribeButton = tester.widget<FilledButton>(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await tester.runAsync(() async {
      transcribeButton.onPressed!();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (
          (await db.getDump(row.id))?.transcript != 'words from this phone') {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for the local transcript to persist');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('words from this phone'), findsOneWidget);
    final saved = await db.getDump(row.id);
    expect(saved!.transcript, 'words from this phone');
    expect(saved.syncStatus, 'pending');
  });

  testWidgets('Meeting detail prioritizes notes and expands raw transcript',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-detail-meeting-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });
    await db.upsertDump(
      DumpRow(
        id: 'meeting-detail',
        createdAt: DateTime.utc(2026, 9, 14),
        updatedAt: DateTime.utc(2026, 9, 14),
        mode: 'meeting',
        durationSeconds: 4,
        title: 'Launch meeting',
        transcript: 'Exact raw transcript words.',
        meetingNotes: '# Launch\n\n## Summary\n\nQuoted summary.',
        audioPath: storage.pathFor('meeting-detail').path,
        audioSizeBytes: 3,
        syncStatus: 'pending',
        syncAttempts: 0,
      ),
    );
    storage.pathFor('meeting-detail').writeAsBytesSync([1, 2, 3]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            _TestPlaybackEngine.new,
          ),
        ],
        child: const MaterialApp(
          home: DumpDetailScreen(
            dumpId: 'meeting-detail',
            audioPath: 'unused',
            durationSeconds: 4,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Meeting Notes'), findsOneWidget);
    expect(find.textContaining('Quoted summary.'), findsOneWidget);
    expect(find.text('Exact raw transcript words.'), findsNothing);

    // The Raw Transcript is inside an ExpansionTile; the screen content may
    // exceed the test viewport, so scroll it into view first, then tap.
    final tileFinder = find.widgetWithText(ExpansionTile, 'Raw Transcript');
    await tester.dragUntilVisible(
      tileFinder,
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.tap(tileFinder);
    await tester.pumpAndSettle();
    expect(find.text('Exact raw transcript words.'), findsOneWidget);
  });
}

final class _TestPlaybackEngine implements RecordingPlaybackEngine {
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Future<Duration?> load(String source) async => const Duration(seconds: 4);
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

final class _FakeLocalService extends OnDeviceTranscriptionService {
  _FakeLocalService()
      : super(
          decoder: _UnusedDecoder(),
          runtime: _UnusedRuntime(),
          temporaryDirectory: Directory.systemTemp.createTemp,
        );

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required LocalTranscriptionProgressCallback onProgress,
  }) async {
    expect(audio, [1, 2, 3]);
    onProgress(
      const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.transcribing,
        fraction: 0.5,
      ),
    );
    return 'words from this phone';
  }
}

final class _UnusedDecoder implements LocalAudioDecoder {
  @override
  Future<File> decodeToWav(Uint8List source, Directory temporaryDirectory) =>
      throw UnimplementedError();
}

final class _UnusedRuntime implements LocalWhisperRuntime {
  @override
  void cancel() {}
  @override
  Future<void> installModel({required ModelProgressCallback onProgress}) =>
      throw UnimplementedError();
  @override
  Future<bool> isModelInstalled() => throw UnimplementedError();
  @override
  Future<String> transcribe(
    File wav, {
    required ModelLoadedCallback onModelLoaded,
    required InferenceProgressCallback onProgress,
  }) =>
      throw UnimplementedError();
}

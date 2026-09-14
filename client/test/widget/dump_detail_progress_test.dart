// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/services/local_transcription_coordinator.dart';
import 'package:tangent/services/on_device_transcription.dart';
import 'package:tangent/services/recording_playback.dart';

void main() {
  testWidgets('model loading stays visible after Dump screen reattachment',
      (tester) async {
    final temp =
        Directory.systemTemp.createTempSync('tangent-progress-widget-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final coordinator = _LoadingCoordinator(
      db: db,
      audioStorage: storage,
      startedAt: DateTime.now(),
    );
    final container = ProviderContainer(
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
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
      temp.deleteSync(recursive: true);
    });

    final row = DumpRow(
      id: 'visible-progress',
      createdAt: DateTime.utc(2026, 9, 13),
      updatedAt: DateTime.utc(2026, 9, 13),
      mode: 'brain_dump',
      durationSeconds: 20,
      title: 'Visible progress',
      audioPath: storage.pathFor('visible-progress').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
    );
    await db.upsertDump(row);

    Future<void> mountDetail() => tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: DumpDetailScreen(
                dumpId: 'visible-progress',
                audioPath: 'unused',
                durationSeconds: 20,
              ),
            ),
          ),
        );

    await mountDetail();
    await tester.pump();
    expect(find.text('Loading Whisper large-v3-turbo'), findsOneWidget);
    expect(find.textContaining('1.5 GB'), findsOneWidget);
    expect(
      find.textContaining('First load can take roughly a minute'),
      findsOneWidget,
    );
    expect(find.textContaining('Elapsed 00:'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .value,
      isNull,
    );
    expect(find.text('Cancel'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await mountDetail();
    await tester.pump();

    expect(find.text('Loading Whisper large-v3-turbo'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
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

final class _LoadingCoordinator extends LocalTranscriptionCoordinator {
  _LoadingCoordinator({
    required super.db,
    required super.audioStorage,
    required DateTime startedAt,
  })  : _operation = LocalTranscriptionOperation(
          status: LocalTranscriptionStatus.running,
          dumpId: 'visible-progress',
          startedAt: startedAt,
          progress: const LocalTranscriptionProgress(
            stage: LocalTranscriptionStage.loadingModel,
          ),
        ),
        super(service: _UnusedLocalService());

  final LocalTranscriptionOperation _operation;

  @override
  LocalTranscriptionOperation get operation => _operation;

  @override
  LocalTranscriptionOperation operationFor(String dumpId) =>
      dumpId == _operation.dumpId
          ? _operation
          : const LocalTranscriptionOperation.idle();
}

final class _UnusedLocalService extends OnDeviceTranscriptionService {
  _UnusedLocalService()
      : super(
          decoder: _UnusedDecoder(),
          runtime: _UnusedRuntime(),
          temporaryDirectory: Directory.systemTemp.createTemp,
        );
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

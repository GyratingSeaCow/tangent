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
  testWidgets('Dump detail plays, pauses, and seeks through its recording',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-playback-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final engine = _FakePlaybackEngine();
    final coordinator = LocalTranscriptionCoordinator(
      service: _UnusedLocalService(),
      db: db,
      audioStorage: storage,
    );
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = DumpRow(
      id: 'playback-1',
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
      mode: 'brain_dump',
      durationSeconds: 20,
      title: 'Review me',
      audioPath: 'content://tangent/playback-1.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
    );
    await db.upsertDump(row);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          localTranscriptionCoordinatorProvider.overrideWith(
            (ref) => coordinator,
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(
            () => engine,
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
            audioPath: row.audioPath,
            durationSeconds: row.durationSeconds,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(engine.loadedSource, row.audioPath);
    expect(find.text('Recording playback'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('00:00 / 00:20'), findsOneWidget);

    await tester.tap(find.byTooltip('Play recording'));
    await tester.pump();
    expect(engine.playCount, 1);

    engine.emitPosition(const Duration(seconds: 7));
    await tester.pump();
    expect(find.text('00:07 / 00:20'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeEnd!(15);
    await tester.pump();
    expect(engine.lastSeek, const Duration(seconds: 15));

    await tester.tap(find.byTooltip('Pause recording'));
    await tester.pump();
    expect(engine.pauseCount, 1);
  });
}

final class _FakePlaybackEngine implements RecordingPlaybackEngine {
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? loadedSource;
  Duration? lastSeek;
  int playCount = 0;
  int pauseCount = 0;

  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Future<Duration?> load(String source) async {
    loadedSource = source;
    return const Duration(seconds: 20);
  }

  @override
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _positions.add(position);
  }

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _completed.close();
  }

  void emitPosition(Duration value) => _positions.add(value);
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

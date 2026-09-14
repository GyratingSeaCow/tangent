// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/local_transcription_coordinator.dart';
import 'package:tangent/services/on_device_transcription.dart';

void main() {
  test('operation state survives screen reattachment and persists the result',
      () async {
    final temp = Directory.systemTemp.createTempSync('tangent-coordinator-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final service = _BlockingLocalService();
    final coordinator = LocalTranscriptionCoordinator(
      service: service,
      db: db,
      audioStorage: storage,
    );
    addTearDown(() async {
      coordinator.dispose();
      await db.close();
      temp.deleteSync(recursive: true);
    });

    final row = DumpRow(
      id: 'local-progress',
      createdAt: DateTime.utc(2026, 9, 13),
      updatedAt: DateTime.utc(2026, 9, 13),
      mode: 'brain_dump',
      durationSeconds: 20,
      title: 'Progress test',
      audioPath: storage.pathFor('local-progress').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
    );
    await db.upsertDump(row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);

    final operation = coordinator.transcribeDump(row.id);
    await service.started.future;
    service.emit(
      const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.loadingModel,
      ),
    );

    expect(coordinator.operation.dumpId, row.id);
    expect(coordinator.operation.isActive, isTrue);
    expect(
      coordinator.operation.progress?.stage,
      LocalTranscriptionStage.loadingModel,
    );
    expect(coordinator.operation.startedAt, isNotNull);

    // A newly mounted screen reads the same coordinator instead of losing the
    // operation in disposed widget-local state.
    final reattachedOperation = coordinator.operation;
    expect(reattachedOperation.dumpId, row.id);
    expect(reattachedOperation.isActive, isTrue);

    service.complete('  words from this phone  ');
    await operation;

    expect(coordinator.operation.status, LocalTranscriptionStatus.complete);
    expect(coordinator.operation.transcript, 'words from this phone');
    final saved = await db.getDump(row.id);
    expect(saved!.transcript, 'words from this phone');
    expect(saved.syncStatus, 'pending');
    final sidecar = jsonDecode(storage.metaPathFor(row.id).readAsStringSync())
        as Map<String, dynamic>;
    expect(sidecar['transcript'], 'words from this phone');
  });
}

final class _BlockingLocalService extends OnDeviceTranscriptionService {
  _BlockingLocalService()
      : super(
          decoder: _UnusedDecoder(),
          runtime: _UnusedRuntime(),
          temporaryDirectory: Directory.systemTemp.createTemp,
        );

  final started = Completer<void>();
  final _result = Completer<String>();
  LocalTranscriptionProgressCallback? _onProgress;

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required LocalTranscriptionProgressCallback onProgress,
  }) {
    expect(audio, [1, 2, 3]);
    _onProgress = onProgress;
    started.complete();
    return _result.future;
  }

  void emit(LocalTranscriptionProgress progress) => _onProgress!(progress);

  void complete(String transcript) => _result.complete(transcript);
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

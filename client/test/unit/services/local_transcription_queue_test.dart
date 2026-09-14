// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: require_trailing_commas
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/local_transcription_coordinator.dart';
import 'package:tangent/services/on_device_transcription.dart';

void main() {
  late Directory temp;
  late LocalDb db;
  late AudioStorage storage;
  late _SerialService service;
  late LocalTranscriptionCoordinator coordinator;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tangent-queue-');
    db = LocalDb.forTesting(NativeDatabase.memory());
    storage = AudioStorage.test(temp);
    service = _SerialService();
    coordinator = LocalTranscriptionCoordinator(
      service: service,
      db: db,
      audioStorage: storage,
    );
    for (final entry in ['one', 'two', 'three'].asMap().entries) {
      final id = entry.value;
      await db.upsertDump(DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 14),
        updatedAt: DateTime.utc(2026, 9, 14),
        mode: 'brain_dump',
        durationSeconds: 2,
        title: id,
        audioPath: storage.pathFor(id).path,
        audioSizeBytes: 1,
        syncStatus: 'pending',
        syncAttempts: 0,
      ));
      storage.pathFor(id).writeAsBytesSync([entry.key + 1]);
    }
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
    temp.deleteSync(recursive: true);
  });

  test('enqueue while active runs jobs in FIFO order', () async {
    final first = coordinator.transcribeDump('one');
    await service.waitForStarts(1);
    final second = coordinator.transcribeDump('two');
    final third = coordinator.transcribeDump('three');

    expect(coordinator.operationFor('one').status,
        LocalTranscriptionStatus.running);
    expect(coordinator.operationFor('two').status,
        LocalTranscriptionStatus.queued);
    expect(coordinator.queuePosition('two'), 1);
    expect(coordinator.queuePosition('three'), 2);

    service.completeCurrent('first words');
    await service.waitForStarts(2);
    expect(service.startedIds, ['one', 'two']);
    service.completeCurrent('second words');
    await service.waitForStarts(3);
    expect(service.startedIds, ['one', 'two', 'three']);
    service.completeCurrent('third words');
    await Future.wait([first, second, third]);
  });

  test('duplicate taps return the same queued future', () async {
    final first = coordinator.transcribeDump('one');
    await service.waitForStarts(1);
    final a = coordinator.transcribeDump('two');
    final b = coordinator.transcribeDump('two');
    expect(identical(a, b), isTrue);
    expect(coordinator.queuedDumpIds, ['two']);
    service.completeCurrent('one done');
    await first;
    await service.waitForStarts(2);
    service.completeCurrent('two done');
    await a;
  });

  test('queued cancellation removes only that item and advances queue',
      () async {
    final first = coordinator.transcribeDump('one');
    await service.waitForStarts(1);
    final removed = coordinator.transcribeDump('two');
    final third = coordinator.transcribeDump('three');

    coordinator.cancel('two');
    await removed;
    expect(
        coordinator.operationFor('two').status, LocalTranscriptionStatus.idle);
    expect(service.cancelCalls, 0);
    expect(coordinator.queuePosition('three'), 1);

    service.completeCurrent('one done');
    await first;
    await service.waitForStarts(2);
    expect(service.startedIds, ['one', 'three']);
    service.completeCurrent('three done');
    await third;
  });

  test('queue advances after active error', () async {
    final first = coordinator.transcribeDump('one');
    await service.waitForStarts(1);
    final second = coordinator.transcribeDump('two');
    service.failCurrent(StateError('native failure'));
    await first;
    await service.waitForStarts(2);
    expect(
        coordinator.operationFor('one').status, LocalTranscriptionStatus.error);
    service.completeCurrent('recovered');
    await second;
    expect((await db.getDump('two'))!.transcript, 'recovered');
  });

  test('queue advances after active cancellation completes', () async {
    service.cancelCompletesCurrent = true;
    final first = coordinator.transcribeDump('one');
    await service.waitForStarts(1);
    final second = coordinator.transcribeDump('two');

    coordinator.cancel('one');
    expect(coordinator.operationFor('one').status,
        LocalTranscriptionStatus.cancelling);
    await first;
    await service.waitForStarts(2);
    expect(service.startedIds, ['one', 'two']);
    service.completeCurrent('after cancellation');
    await second;
  });
}

final class _SerialService extends OnDeviceTranscriptionService {
  _SerialService()
      : super(
          decoder: _UnusedDecoder(),
          runtime: _UnusedRuntime(),
          temporaryDirectory: Directory.systemTemp.createTemp,
        );

  final startedIds = <String>[];
  final _starts = StreamController<void>.broadcast();
  Completer<String>? _current;
  int cancelCalls = 0;
  bool cancelCompletesCurrent = false;

  Future<void> waitForStarts(int count) async {
    while (startedIds.length < count) {
      await _starts.stream.first;
    }
  }

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required LocalTranscriptionProgressCallback onProgress,
  }) {
    final id = ['one', 'two', 'three'][audio.single - 1];
    startedIds.add(id);
    _current = Completer<String>();
    _starts.add(null);
    return _current!.future;
  }

  void completeCurrent(String value) => _current!.complete(value);
  void failCurrent(Object error) => _current!.completeError(error);

  @override
  void cancel() {
    cancelCalls++;
    if (cancelCompletesCurrent && !(_current?.isCompleted ?? true)) {
      _current!.completeError(
        const LocalTranscriptionException('Transcription was cancelled'),
      );
    }
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
  Future<String> transcribe(File wav,
          {required ModelLoadedCallback onModelLoaded,
          required InferenceProgressCallback onProgress}) =>
      throw UnimplementedError();
}

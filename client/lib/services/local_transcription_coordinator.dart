// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../data/audio_storage.dart';
import '../data/local_db.dart';
import '../data/recording_metadata.dart';
import 'on_device_transcription.dart';

enum LocalTranscriptionStatus {
  idle,
  running,
  cancelling,
  complete,
  error,
}

@immutable
final class LocalTranscriptionOperation {
  const LocalTranscriptionOperation({
    required this.status,
    this.dumpId,
    this.progress,
    this.startedAt,
    this.transcript,
    this.error,
  });

  const LocalTranscriptionOperation.idle()
      : status = LocalTranscriptionStatus.idle,
        dumpId = null,
        progress = null,
        startedAt = null,
        transcript = null,
        error = null;

  final LocalTranscriptionStatus status;
  final String? dumpId;
  final LocalTranscriptionProgress? progress;
  final DateTime? startedAt;
  final String? transcript;
  final String? error;

  bool get isActive =>
      status == LocalTranscriptionStatus.running ||
      status == LocalTranscriptionStatus.cancelling;
}

class LocalTranscriptionCoordinator extends ChangeNotifier {
  LocalTranscriptionCoordinator({
    required OnDeviceTranscriptionService service,
    required LocalDb db,
    required AudioStorage audioStorage,
  })  : _service = service,
        _db = db,
        _audioStorage = audioStorage;

  final OnDeviceTranscriptionService _service;
  final LocalDb _db;
  final AudioStorage _audioStorage;

  LocalTranscriptionOperation _operation =
      const LocalTranscriptionOperation.idle();
  Future<void>? _activeFuture;

  LocalTranscriptionOperation get operation => _operation;

  Future<void> transcribeDump(String dumpId) {
    if (_operation.isActive) {
      if (_operation.dumpId == dumpId && _activeFuture != null) {
        return _activeFuture!;
      }
      throw const LocalTranscriptionException(
        'Another on-device transcription operation is already running',
      );
    }

    final future = _run(dumpId);
    _activeFuture = future;
    return future;
  }

  Future<void> _run(String dumpId) async {
    _setOperation(
      LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.running,
        dumpId: dumpId,
        startedAt: DateTime.now(),
        progress: const LocalTranscriptionProgress(
          stage: LocalTranscriptionStage.preparingAudio,
          fraction: 0,
        ),
      ),
    );

    try {
      final row = await _db.getDump(dumpId);
      if (row == null) throw StateError('Dump not found');
      final audioBytes = await _audioStorage.readBytes(row.id);
      final transcript = (await _service.transcribe(
        audioBytes,
        onProgress: (progress) {
          if (!_operation.isActive || _operation.dumpId != dumpId) return;
          _setOperation(
            LocalTranscriptionOperation(
              status: _operation.status,
              dumpId: dumpId,
              startedAt: _operation.startedAt,
              progress: progress,
            ),
          );
        },
      ))
          .trim();
      if (transcript.isEmpty) {
        throw const LocalTranscriptionException(
          'The on-device model returned an empty transcript',
        );
      }

      final completed = row.copyWith(
        transcript: Value(transcript),
        syncStatus: row.syncStatus,
        updatedAt: DateTime.now().toUtc(),
      );
      await _audioStorage.writeMetadata(
        completed.id,
        dumpMetadata(completed),
      );
      await _db.upsertDump(completed);
      _setOperation(
        LocalTranscriptionOperation(
          status: LocalTranscriptionStatus.complete,
          dumpId: dumpId,
          startedAt: _operation.startedAt,
          progress: const LocalTranscriptionProgress(
            stage: LocalTranscriptionStage.complete,
            fraction: 1,
          ),
          transcript: transcript,
        ),
      );
    } catch (error) {
      _setOperation(
        LocalTranscriptionOperation(
          status: LocalTranscriptionStatus.error,
          dumpId: dumpId,
          startedAt: _operation.startedAt,
          progress: _operation.progress,
          error: error.toString(),
        ),
      );
    } finally {
      _activeFuture = null;
    }
  }

  void cancel() {
    if (!_operation.isActive) return;
    _setOperation(
      LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.cancelling,
        dumpId: _operation.dumpId,
        startedAt: _operation.startedAt,
        progress: _operation.progress,
      ),
    );
    _service.cancel();
  }

  void _setOperation(LocalTranscriptionOperation value) {
    _operation = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_operation.isActive) _service.cancel();
    super.dispose();
  }
}

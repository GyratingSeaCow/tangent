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
  queued,
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
    this.queuePosition,
  });

  const LocalTranscriptionOperation.idle()
      : status = LocalTranscriptionStatus.idle,
        dumpId = null,
        progress = null,
        startedAt = null,
        transcript = null,
        error = null,
        queuePosition = null;

  final LocalTranscriptionStatus status;
  final String? dumpId;
  final LocalTranscriptionProgress? progress;
  final DateTime? startedAt;
  final String? transcript;
  final String? error;
  final int? queuePosition;

  bool get isActive =>
      status == LocalTranscriptionStatus.running ||
      status == LocalTranscriptionStatus.cancelling;
}

final class _QueuedTranscription {
  _QueuedTranscription(this.dumpId);
  final String dumpId;
  final Completer<void> completer = Completer<void>();
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
  final List<_QueuedTranscription> _queue = [];
  final Map<String, LocalTranscriptionOperation> _terminal = {};
  _QueuedTranscription? _activeJob;
  LocalTranscriptionOperation _activeOperation =
      const LocalTranscriptionOperation.idle();
  LocalTranscriptionOperation _lastOperation =
      const LocalTranscriptionOperation.idle();
  bool _disposed = false;

  LocalTranscriptionOperation get operation =>
      _activeJob == null ? _lastOperation : _activeOperation;

  List<String> get queuedDumpIds =>
      List.unmodifiable(_queue.map((job) => job.dumpId));

  int? queuePosition(String dumpId) {
    final index = _queue.indexWhere((job) => job.dumpId == dumpId);
    return index < 0 ? null : index + 1;
  }

  LocalTranscriptionOperation operationFor(String dumpId) {
    if (_activeJob?.dumpId == dumpId) return _activeOperation;
    final position = queuePosition(dumpId);
    if (position != null) {
      return LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.queued,
        dumpId: dumpId,
        queuePosition: position,
      );
    }
    return _terminal[dumpId] ?? const LocalTranscriptionOperation.idle();
  }

  Future<void> transcribeDump(String dumpId) {
    if (_disposed) throw StateError('Coordinator is disposed');
    if (_activeJob?.dumpId == dumpId) return _activeJob!.completer.future;
    final existing = _queue.where((job) => job.dumpId == dumpId).firstOrNull;
    if (existing != null) return existing.completer.future;

    final job = _QueuedTranscription(dumpId);
    _queue.add(job);
    _terminal.remove(dumpId);
    _notify();
    _startNext();
    return job.completer.future;
  }

  void _startNext() {
    if (_disposed || _activeJob != null || _queue.isEmpty) return;
    final job = _queue.removeAt(0);
    _activeJob = job;
    unawaited(_run(job));
  }

  Future<void> _run(_QueuedTranscription job) async {
    final dumpId = job.dumpId;
    _activeOperation = LocalTranscriptionOperation(
      status: LocalTranscriptionStatus.running,
      dumpId: dumpId,
      startedAt: DateTime.now(),
      progress: const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.preparingAudio,
        fraction: 0,
      ),
    );
    _notify();

    LocalTranscriptionOperation terminal;
    try {
      final row = await _db.getDump(dumpId);
      if (row == null) throw StateError('Dump not found');
      final audioBytes = await _audioStorage.readBytes(row.id);
      final transcript = (await _service.transcribe(
        audioBytes,
        onProgress: (progress) {
          if (_activeJob != job || _disposed) return;
          _activeOperation = LocalTranscriptionOperation(
            status: _activeOperation.status,
            dumpId: dumpId,
            startedAt: _activeOperation.startedAt,
            progress: progress,
          );
          _notify();
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
      await _audioStorage.writeMetadata(completed.id, dumpMetadata(completed));
      await _db.upsertDump(completed);
      terminal = LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.complete,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
        progress: const LocalTranscriptionProgress(
          stage: LocalTranscriptionStage.complete,
          fraction: 1,
        ),
        transcript: transcript,
      );
    } catch (error) {
      terminal = LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.error,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
        progress: _activeOperation.progress,
        error: error.toString(),
      );
    }

    _terminal[dumpId] = terminal;
    _lastOperation = terminal;
    _activeJob = null;
    _activeOperation = const LocalTranscriptionOperation.idle();
    if (!job.completer.isCompleted) job.completer.complete();
    _notify();
    _startNext();
  }

  void cancel([String? dumpId]) {
    final target = dumpId ?? _activeJob?.dumpId;
    if (target == null) return;
    if (_activeJob?.dumpId == target) {
      if (!_activeOperation.isActive) return;
      _activeOperation = LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.cancelling,
        dumpId: target,
        startedAt: _activeOperation.startedAt,
        progress: _activeOperation.progress,
      );
      _notify();
      _service.cancel();
      return;
    }
    final index = _queue.indexWhere((job) => job.dumpId == target);
    if (index < 0) return;
    final removed = _queue.removeAt(index);
    if (!removed.completer.isCompleted) removed.completer.complete();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_activeOperation.isActive) _service.cancel();
    for (final job in _queue) {
      if (!job.completer.isCompleted) job.completer.complete();
    }
    _queue.clear();
    super.dispose();
  }
}

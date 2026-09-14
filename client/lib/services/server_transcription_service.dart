// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/audio_storage.dart';
import '../data/local_db.dart';
import '../data/recording_metadata.dart';
import 'meeting_notes_processor.dart';
import 'server_transcription.dart';
import 'transcription_client.dart';

/// Per-dump and aggregate state for server-side transcription.
///
/// The server owns execution while this service tracks per-dump state for
/// the Dumps list and detail progress panel.

final class _QueuedTranscription {
  _QueuedTranscription(this.dumpId);
  final String dumpId;
  final Completer<void> completer = Completer<void>();
}

class ServerTranscriptionService extends ChangeNotifier {
  ServerTranscriptionService({
    required TranscriptionClient client,
    required LocalDb db,
    required AudioStorage audioStorage,
    MeetingNotesProcessor meetingNotesProcessor = const MeetingNotesProcessor(),
  })  : _client = client,
        _db = db,
        _audioStorage = audioStorage,
        _meetingNotesProcessor = meetingNotesProcessor;

  final TranscriptionClient _client;
  final LocalDb _db;
  final AudioStorage _audioStorage;
  final MeetingNotesProcessor _meetingNotesProcessor;

  final List<_QueuedTranscription> _queue = [];
  final Map<String, ServerTranscriptionOperation> _terminal = {};
  _QueuedTranscription? _activeJob;
  ServerTranscriptionOperation _activeOperation =
      const ServerTranscriptionOperation.idle();
  ServerTranscriptionOperation _lastOperation =
      const ServerTranscriptionOperation.idle();
  bool _disposed = false;

  ServerTranscriptionOperation get operation =>
      _activeJob == null ? _lastOperation : _activeOperation;

  List<String> get queuedDumpIds =>
      List.unmodifiable(_queue.map((job) => job.dumpId));

  int? queuePosition(String dumpId) {
    final index = _queue.indexWhere((job) => job.dumpId == dumpId);
    return index < 0 ? null : index + 1;
  }

  ServerTranscriptionOperation operationFor(String dumpId) {
    if (_activeJob?.dumpId == dumpId) return _activeOperation;
    final position = queuePosition(dumpId);
    if (position != null) {
      return ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.queued,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
      );
    }
    return _terminal[dumpId] ?? const ServerTranscriptionOperation.idle();
  }

  /// Upload audio (if not yet on the server) and enqueue a transcription
  /// job. Returns a future that completes when the job reaches a terminal
  /// state (`complete` or `error`). Duplicate taps for an active or queued
  /// dump return the same future.
  Future<void> transcribeDump(String dumpId) {
    if (_disposed) throw StateError('ServerTranscriptionService is disposed');
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
    _activeOperation = ServerTranscriptionOperation(
      status: ServerTranscriptionStatus.uploading,
      dumpId: dumpId,
      startedAt: DateTime.now(),
    );
    _notify();

    ServerTranscriptionOperation terminal;
    try {
      final row = await _db.getDump(dumpId);
      if (row == null) {
        throw const LocalTranscriptionServerError('Dump not found');
      }
      final audioBytes = await _audioStorage.readBytes(row.id);
      if (audioBytes.isEmpty) {
        throw const LocalTranscriptionServerError('Audio file is empty');
      }

      // Ensure the server has the dump metadata + audio. The server is
      // idempotent on `id`, so re-sending is safe even when a previous
      // sync already uploaded the audio but transcription failed.
      await _client.createDump(
        id: row.id,
        mode: row.mode,
        durationSeconds: row.durationSeconds,
        title: row.title,
        createdAt: row.createdAt,
      );
      await _client.uploadAudio(
        dumpId: row.id,
        audioBytes: audioBytes,
      );

      _activeOperation = ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.queued,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
      );
      _notify();

      final job = await _client.enqueueTranscription(
        row.id,
        requestId: const Uuid().v4(),
      );
      String? transcript;
      await for (final event in _client.streamJob(job.id)) {
        switch (event.status) {
          case 'queued':
            // Server confirmed queue position; no action needed.
            break;
          case 'running':
            _activeOperation = ServerTranscriptionOperation(
              status: ServerTranscriptionStatus.running,
              dumpId: dumpId,
              startedAt: _activeOperation.startedAt,
            );
            _notify();
          case 'completed':
            transcript = event.data['transcript']?.toString().trim() ?? '';
            break;
          case 'failed':
            throw LocalTranscriptionServerError(
              event.data['error']?.toString() ?? 'Server job failed',
            );
          case 'error':
            throw const LocalTranscriptionServerError('Server SSE error');
          case 'timeout':
            throw const LocalTranscriptionServerError(
              'Server did not complete the job in time',
            );
          default:
            // Unknown event: keep waiting.
            break;
        }
        if (event.status == 'completed') break;
      }

      if (transcript == null || transcript.isEmpty) {
        throw const LocalTranscriptionServerError(
          'Server returned an empty transcript',
        );
      }

      final meetingNotes = row.mode == 'meeting'
          ? _meetingNotesProcessor.process(
              title: row.title,
              transcript: transcript,
            )
          : null;
      final completed = row.copyWith(
        transcript: Value(transcript),
        meetingNotes:
            meetingNotes != null ? Value(meetingNotes) : const Value.absent(),
        updatedAt: DateTime.now().toUtc(),
      );
      await _audioStorage.writeMetadata(completed.id, dumpMetadata(completed));
      await _db.upsertDump(completed);
      terminal = ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.complete,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
        transcript: transcript,
      );
    } catch (error) {
      terminal = ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.error,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
        error: error.toString(),
      );
    }

    _terminal[dumpId] = terminal;
    _lastOperation = terminal;
    _activeJob = null;
    _activeOperation = const ServerTranscriptionOperation.idle();
    if (!job.completer.isCompleted) job.completer.complete();
    _notify();
    _startNext();
  }

  /// Cancel a queued or active dump. Active jobs have no server-side
  /// cancellation in v1, so the request is purely advisory: queued jobs
  /// are removed before they start; active jobs transition to `cancelling`
  /// and the SSE stream is allowed to finish naturally.
  void cancel([String? dumpId]) {
    final target = dumpId ?? _activeJob?.dumpId;
    if (target == null) return;
    if (_activeJob?.dumpId == target) {
      if (!_activeOperation.isActive) return;
      _activeOperation = ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.cancelling,
        dumpId: target,
        startedAt: _activeOperation.startedAt,
      );
      _notify();
      return;
    }
    final index = _queue.indexWhere((job) => job.dumpId == target);
    if (index < 0) return;
    final removed = _queue.removeAt(index);
    if (!removed.completer.isCompleted) removed.completer.complete();
    _terminal[target] = ServerTranscriptionOperation(
      status: ServerTranscriptionStatus.error,
      dumpId: target,
      startedAt: _activeOperation.startedAt,
      error: 'Cancelled before start',
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _queue) {
      if (!job.completer.isCompleted) job.completer.complete();
    }
    _queue.clear();
    super.dispose();
  }
}

/// Sentinel error for server-transcription failures. Distinct from
/// `LocalTranscriptionException` (which still exists in case the project
/// resurrects on-device Whisper later) so the UI can render a different
/// message.
class LocalTranscriptionServerError implements Exception {
  const LocalTranscriptionServerError(this.message);
  final String message;
  @override
  String toString() => 'LocalTranscriptionServerError: $message';
}

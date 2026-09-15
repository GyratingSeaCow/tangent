// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/audio_storage.dart';
import '../data/local_db.dart';
import '../data/recording_metadata.dart';
import '../models/api_exception.dart';
import '../models/transcription_status.dart';
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
    String Function()? requestIdFactory,
    DateTime Function()? now,
    Future<void> Function(String, Map<String, dynamic>)? metadataWriter,
    Duration recoveryRequestTimeout = const Duration(seconds: 30),
  })  : _client = client,
        _db = db,
        _audioStorage = audioStorage,
        _meetingNotesProcessor = meetingNotesProcessor,
        _requestIdFactory = requestIdFactory ?? const Uuid().v4,
        _now = now ?? (() => DateTime.now().toUtc()),
        _metadataWriterOverride = metadataWriter,
        _recoveryRequestTimeout = recoveryRequestTimeout;

  final TranscriptionClient _client;
  final LocalDb _db;
  final AudioStorage _audioStorage;
  final MeetingNotesProcessor _meetingNotesProcessor;
  final String Function() _requestIdFactory;
  final DateTime Function() _now;
  final Future<void> Function(String, Map<String, dynamic>)?
      _metadataWriterOverride;
  final Duration _recoveryRequestTimeout;

  final List<_QueuedTranscription> _queue = [];
  final Map<String, DumpRow> _durableRows = {};
  final Map<String, Future<void>> _reattachments = {};
  Future<void>? _reconciliationScan;
  _QueuedTranscription? _activeJob;
  ServerTranscriptionOperation _activeOperation =
      const ServerTranscriptionOperation.idle();
  String? _lastDumpId;
  bool _disposed = false;

  ServerTranscriptionOperation get operation {
    if (_activeJob != null) return operationFor(_activeJob!.dumpId);
    return _lastDumpId == null
        ? const ServerTranscriptionOperation.idle()
        : operationFor(_lastDumpId!);
  }

  List<String> get queuedDumpIds =>
      List.unmodifiable(_queue.map((job) => job.dumpId));

  Future<void> reconcilePending() {
    if (_disposed) return Future<void>.value();
    final activeScan = _reconciliationScan;
    if (activeScan != null) return activeScan;

    late final Future<void> scan;
    scan = _scanPending().whenComplete(() {
      if (identical(_reconciliationScan, scan)) _reconciliationScan = null;
    });
    _reconciliationScan = scan;
    return scan;
  }

  Future<void> _scanPending() async {
    late final List<DumpRow> rows;
    try {
      rows = await _db.dumpsNeedingTranscriptionRecovery();
    } catch (_) {
      return;
    }
    await Future.wait(
      rows.map((row) async {
        final attachment = await _resolvePendingRow(row);
        if (attachment == null) return;
        final (attachmentRow, jobId) = attachment;
        _startReattachment(attachmentRow, jobId);
      }),
    );
  }

  Future<(DumpRow, String)?> _resolvePendingRow(DumpRow row) async {
    try {
      if (TranscriptionStatus.fromWire(row.transcriptionStatus) ==
          TranscriptionStatus.completed) {
        await _repairCompletedSidecar(row);
        return null;
      }
      final jobId = row.transcriptionJobId;
      if (jobId == null) {
        final requestId = row.transcriptionRequestId;
        if (requestId == null) return null;
        late TranscriptionJobSnapshot snapshot;
        var repairedMetadata = false;
        var repairedAudio = false;
        while (true) {
          try {
            snapshot = await _awaitRecoveryRequest(
              _client.enqueueTranscription(
                row.id,
                requestId: requestId,
                model: 'large-v3',
              ),
            );
            break;
          } on ApiException catch (error) {
            if (error.statusCode == 404 && !repairedMetadata) {
              repairedMetadata = true;
              await _awaitRecoveryRequest(
                _client.createDump(
                  id: row.id,
                  mode: row.mode,
                  durationSeconds: row.durationSeconds,
                  title: row.title,
                  createdAt: row.createdAt,
                ),
              );
              continue;
            }
            if (error.statusCode == 422 &&
                error.code == 'missing_audio' &&
                !repairedAudio) {
              repairedAudio = true;
              final audioBytes = await _audioStorage.readBytes(row.id);
              if (audioBytes.isEmpty) {
                throw const LocalTranscriptionServerError(
                  'Audio file is empty',
                );
              }
              await _awaitRecoveryRequest(
                _client.uploadAudio(
                  dumpId: row.id,
                  audioBytes: audioBytes,
                ),
              );
              continue;
            }
            rethrow;
          }
        }
        if (snapshot.status == 'completed') {
          final accepted = await _guardedStatus(
            row,
            status: TranscriptionStatus.queued,
            jobId: snapshot.id,
          );
          if (!accepted) return null;
          final transcript = snapshot.transcript?.trim();
          if (transcript == null || transcript.isEmpty) {
            await _guardedStatus(
              row,
              status: TranscriptionStatus.failed,
              jobId: snapshot.id,
              error: 'Server returned an empty transcript',
            );
          } else {
            await _persistRecoveredCompletion(row, transcript);
          }
          await _refreshDurableRow(row.id);
          return null;
        }
        if (snapshot.status == 'failed') {
          await _guardedStatus(
            row,
            status: TranscriptionStatus.failed,
            jobId: snapshot.id,
            error: snapshot.error ?? 'Server job failed',
          );
          await _refreshDurableRow(row.id);
          return null;
        }
        final status = switch (snapshot.status) {
          'running' => TranscriptionStatus.running,
          'queued' => TranscriptionStatus.queued,
          _ => throw FormatException(
              'Unknown transcription status: ${snapshot.status}',
            ),
        };
        final accepted =
            await _guardedStatus(row, status: status, jobId: snapshot.id);
        await _refreshDurableRow(row.id);
        return accepted ? (row, snapshot.id) : null;
      }
      final snapshot = await _awaitRecoveryRequest(_client.getJob(jobId));
      if (snapshot.status == 'failed') {
        await _guardedStatus(
          row,
          status: TranscriptionStatus.failed,
          jobId: jobId,
          error: snapshot.error ?? 'Server job failed',
        );
        await _refreshDurableRow(row.id);
        return null;
      }
      if (snapshot.status != 'completed') return (row, jobId);
      final transcript = snapshot.transcript?.trim();
      if (transcript == null || transcript.isEmpty) {
        await _guardedStatus(
          row,
          status: TranscriptionStatus.failed,
          jobId: jobId,
          error: 'Server returned an empty transcript',
        );
        await _refreshDurableRow(row.id);
        return null;
      }
      await _persistRecoveredCompletion(row, transcript);
    } catch (error) {
      if (TranscriptionStatus.fromWire(row.transcriptionStatus) !=
          TranscriptionStatus.completed) {
        if (_isDefinitiveFailure(error)) {
          await _guardedStatus(
            row,
            status: TranscriptionStatus.failed,
            jobId: row.transcriptionJobId,
            error: error.toString(),
          );
        } else {
          await _persistRecoverable(
            row,
            marker: 'reconciliation_pending: $error',
            jobId: row.transcriptionJobId,
          );
        }
      }
      await _refreshDurableRow(row.id);
    }
    return null;
  }

  Future<T> _awaitRecoveryRequest<T>(Future<T> request) {
    return request.timeout(_recoveryRequestTimeout);
  }

  void _startReattachment(DumpRow row, String jobId) {
    if (_disposed || _reattachments.containsKey(row.id)) return;
    late final Future<void> attachment;
    attachment = _watchReattachedJob(row, jobId).whenComplete(() {
      if (identical(_reattachments[row.id], attachment)) {
        _reattachments.remove(row.id);
      }
    });
    _reattachments[row.id] = attachment;
    unawaited(attachment);
  }

  Future<void> _watchReattachedJob(DumpRow row, String jobId) async {
    try {
      await for (final event in _client.streamJob(jobId)) {
        switch (event.status) {
          case 'completed':
            final transcript = event.data['transcript']?.toString().trim();
            if (transcript == null || transcript.isEmpty) {
              await _guardedStatus(
                row,
                status: TranscriptionStatus.failed,
                jobId: jobId,
                error: 'Server returned an empty transcript',
              );
              await _refreshDurableRow(row.id);
            } else {
              await _persistRecoveredCompletion(row, transcript);
            }
            return;
          case 'failed':
            await _guardedStatus(
              row,
              status: TranscriptionStatus.failed,
              jobId: jobId,
              error: event.data['error']?.toString() ?? 'Server job failed',
            );
            await _refreshDurableRow(row.id);
            return;
          case 'error':
          case 'timeout':
            await _storeReattachmentError(
              row,
              jobId,
              event.data['message']?.toString() ??
                  'Server stream reported ${event.status}',
            );
            return;
          default:
            break;
        }
      }
      await _storeReattachmentError(
        row,
        jobId,
        'Event stream ended before a terminal event',
      );
    } catch (error) {
      await _storeReattachmentError(row, jobId, error.toString());
    }
  }

  Future<void> _storeReattachmentError(
    DumpRow row,
    String jobId,
    String error,
  ) async {
    await _persistRecoverable(
      row,
      marker: 'reconciliation_pending: $error',
      jobId: jobId,
    );
    await _refreshDurableRow(row.id);
  }

  Future<void> _persistRecoveredCompletion(
    DumpRow row,
    String transcript,
  ) async {
    final meetingNotes = row.mode == 'meeting'
        ? _meetingNotesProcessor.process(
            title: row.title,
            transcript: transcript,
          )
        : null;
    final completed = await _db.completeTranscriptionAttempt(
      row.id,
      attempt: row.transcriptionAttempt,
      requestId: row.transcriptionRequestId!,
      transcript: transcript,
      meetingNotes: meetingNotes,
      now: _now(),
      sidecarError: 'sidecar_sync_pending: write pending',
    );
    if (!completed) return;
    final committed = await _db.getDump(row.id);
    if (committed == null) return;
    _durableRows[row.id] = committed;
    await _repairCompletedSidecar(committed);
  }

  Future<void> _repairCompletedSidecar(DumpRow row) async {
    await _audioStorage.runSerializedMetadataWrite<void>(
      row.id,
      (write) async {
        final current = await _db.getDump(row.id);
        if (current == null ||
            current.transcriptionAttempt != row.transcriptionAttempt ||
            current.transcriptionRequestId != row.transcriptionRequestId ||
            TranscriptionStatus.fromWire(current.transcriptionStatus) !=
                TranscriptionStatus.completed ||
            !(current.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                false)) {
          return;
        }
        final metadata = dumpMetadata(current)..['transcriptionError'] = null;
        final override = _metadataWriterOverride;
        if (override == null) {
          await write(metadata);
        } else {
          await override(current.id, metadata);
        }
        await _db.updateTranscriptionSidecarError(
          current.id,
          attempt: current.transcriptionAttempt,
          requestId: current.transcriptionRequestId!,
          error: null,
          now: _now(),
        );
        await _refreshDurableRow(current.id);
      },
    );
  }

  int? queuePosition(String dumpId) {
    final index = _queue.indexWhere((job) => job.dumpId == dumpId);
    return index < 0 ? null : index + 1;
  }

  ServerTranscriptionOperation operationFor(
    String dumpId, {
    DumpRow? currentRow,
  }) {
    if (_activeJob?.dumpId == dumpId) return _activeOperation;
    final position = queuePosition(dumpId);
    if (position != null) {
      return ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.queued,
        dumpId: dumpId,
        startedAt: _activeOperation.startedAt,
      );
    }
    if (currentRow != null) {
      _durableRows[dumpId] = currentRow;
      return _operationFromRow(currentRow);
    }
    final durable = _durableRows[dumpId];
    if (durable != null) return _operationFromRow(durable);
    return const ServerTranscriptionOperation.idle();
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

    DumpRow? attemptRow;
    String? remoteJobId;
    try {
      final existing = await _db.getDump(dumpId);
      if (existing == null) {
        throw const LocalTranscriptionServerError('Dump not found');
      }
      _durableRows[existing.id] = existing;
      if (TranscriptionStatus.fromWire(existing.transcriptionStatus)
          .isInProgress) {
        throw const _ExistingDurableTranscription();
      }
      final row = await _db.beginTranscriptionAttempt(
        dumpId,
        requestId: _requestIdFactory(),
        now: _now(),
      );
      attemptRow = row;
      _durableRows[row.id] = row;
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

      final TranscriptionJobSnapshot job;
      try {
        job = await _client.enqueueTranscription(
          row.id,
          requestId: row.transcriptionRequestId!,
        );
      } catch (error) {
        if (_isDefinitiveEnqueueRejection(error)) rethrow;
        final marker = 'enqueue_pending: $error';
        await _guardedStatus(
          row,
          status: TranscriptionStatus.uploading,
          error: marker,
        );
        throw _RecoverableTranscriptionAttempt(marker);
      }
      remoteJobId = job.id;
      final queuedWon = await _guardedStatus(
        row,
        status: TranscriptionStatus.queued,
        jobId: job.id,
      );
      if (!queuedWon) throw const _StaleTranscriptionAttempt();
      _durableRows[row.id] = await _readCurrentAttempt(row);
      String? transcript;
      var sawCompleted = false;
      await for (final event in _client.streamJob(job.id)) {
        switch (event.status) {
          case 'queued':
            // Server confirmed queue position; no action needed.
            break;
          case 'running':
            final runningWon = await _guardedStatus(
              row,
              status: TranscriptionStatus.running,
              jobId: job.id,
            );
            if (!runningWon) throw const _StaleTranscriptionAttempt();
            _durableRows[row.id] = await _readCurrentAttempt(row);
            _activeOperation = ServerTranscriptionOperation(
              status: ServerTranscriptionStatus.running,
              dumpId: dumpId,
              startedAt: _activeOperation.startedAt,
            );
            _notify();
          case 'completed':
            sawCompleted = true;
            transcript = event.data['transcript']?.toString().trim() ?? '';
            break;
          case 'failed':
            throw LocalTranscriptionServerError(
              event.data['error']?.toString() ?? 'Server job failed',
            );
          case 'error':
            throw const _RecoverableTranscriptionAttempt(
              'reconciliation_pending: Server SSE error',
            );
          case 'timeout':
            throw const _RecoverableTranscriptionAttempt(
              'reconciliation_pending: Server did not complete the job in time',
            );
          default:
            // Unknown event: keep waiting.
            break;
        }
        if (event.status == 'completed') break;
      }

      if (!sawCompleted) {
        throw const _RecoverableTranscriptionAttempt(
          'reconciliation_pending: Event stream ended before a terminal event',
        );
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
      bool completionWon;
      try {
        completionWon = await _db.completeTranscriptionAttempt(
          row.id,
          attempt: row.transcriptionAttempt,
          requestId: row.transcriptionRequestId!,
          transcript: transcript,
          meetingNotes: meetingNotes,
          now: _now(),
          sidecarError: 'sidecar_sync_pending: write pending',
        );
      } catch (cause) {
        throw _TranscriptionPersistenceFailure(cause);
      }
      if (!completionWon) throw const _StaleTranscriptionAttempt();
      await _audioStorage.runSerializedMetadataWrite<void>(
        row.id,
        (write) async {
          final completed = await _readCurrentAttempt(row);
          if (completed.transcriptionAttempt != row.transcriptionAttempt ||
              completed.transcriptionRequestId != row.transcriptionRequestId ||
              TranscriptionStatus.fromWire(completed.transcriptionStatus) !=
                  TranscriptionStatus.completed ||
              !(completed.transcriptionError
                      ?.startsWith('sidecar_sync_pending:') ??
                  false)) {
            throw const _StaleTranscriptionAttempt();
          }
          _durableRows[row.id] = completed;
          final sidecarMetadata = dumpMetadata(completed)
            ..['transcriptionError'] = null;
          try {
            final override = _metadataWriterOverride;
            if (override == null) {
              await write(sidecarMetadata);
            } else {
              await override(completed.id, sidecarMetadata);
            }
          } catch (error) {
            try {
              await _db.updateTranscriptionSidecarError(
                completed.id,
                attempt: completed.transcriptionAttempt,
                requestId: completed.transcriptionRequestId!,
                error: 'sidecar_sync_pending: $error',
                now: _now(),
              );
            } catch (_) {
              // Atomic completion already left the generic pending marker.
            }
            return;
          }
          try {
            final cleared = await _db.updateTranscriptionSidecarError(
              completed.id,
              attempt: completed.transcriptionAttempt,
              requestId: completed.transcriptionRequestId!,
              error: null,
              now: _now(),
            );
            if (!cleared) throw const _StaleTranscriptionAttempt();
          } on _StaleTranscriptionAttempt {
            rethrow;
          } catch (cause) {
            throw _TranscriptionPersistenceFailure(cause);
          }
        },
      );
    } on _RecoverableTranscriptionAttempt catch (recoverable) {
      if (attemptRow != null) {
        await _persistRecoverable(
          attemptRow,
          marker: recoverable.marker,
          jobId: remoteJobId,
        );
      }
    } on _TranscriptionPersistenceFailure {
      // Never convert a SQLite failure into a definitive remote-job failure.
      // The durable request/job identity remains eligible for reconciliation.
    } on _StaleTranscriptionAttempt {
      // A newer attempt owns the row; this flow must not touch it.
    } on _ExistingDurableTranscription {
      // Another coordinator already owns the durable attempt.
    } catch (error) {
      if (attemptRow != null) {
        final postEnqueueUncertain =
            remoteJobId != null && !_isDefinitiveFailure(error);
        if (postEnqueueUncertain || _isAmbiguousEnqueueFailure(error)) {
          await _persistRecoverable(
            attemptRow,
            marker: 'reconciliation_pending: $error',
            jobId: remoteJobId,
          );
        } else {
          try {
            await _guardedStatus(
              attemptRow,
              status: TranscriptionStatus.failed,
              jobId: remoteJobId,
              error: error.toString(),
            );
          } catch (_) {
            // Cleanup below must still release this item and advance the queue.
          }
        }
      }
    } finally {
      _lastDumpId = dumpId;
      await _refreshDurableRow(dumpId);
      if (_activeJob == job) {
        _activeJob = null;
        _activeOperation = const ServerTranscriptionOperation.idle();
      }
      if (!job.completer.isCompleted) job.completer.complete();
      _notify();
      _startNext();
    }
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
    _lastDumpId = target;
    _notify();
  }

  ServerTranscriptionOperation _operationFromRow(DumpRow row) {
    final status =
        switch (TranscriptionStatus.fromWire(row.transcriptionStatus)) {
      TranscriptionStatus.notTranscribed => ServerTranscriptionStatus.idle,
      TranscriptionStatus.uploading => ServerTranscriptionStatus.uploading,
      TranscriptionStatus.queued => ServerTranscriptionStatus.queued,
      TranscriptionStatus.running => ServerTranscriptionStatus.running,
      TranscriptionStatus.completed => ServerTranscriptionStatus.complete,
      TranscriptionStatus.failed => ServerTranscriptionStatus.error,
    };
    return ServerTranscriptionOperation(
      status: status,
      dumpId: row.id,
      startedAt: row.transcriptionStartedAt,
      transcript: row.transcript,
      error: row.transcriptionError,
    );
  }

  Future<bool> _guardedStatus(
    DumpRow attempt, {
    required TranscriptionStatus status,
    String? jobId,
    String? error,
  }) async {
    try {
      return await _db.updateTranscriptionStatus(
        attempt.id,
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        status: status,
        now: _now(),
        jobId: jobId,
        error: error,
      );
    } catch (cause) {
      throw _TranscriptionPersistenceFailure(cause);
    }
  }

  Future<DumpRow> _readCurrentAttempt(DumpRow attempt) async {
    try {
      final current = await _db.getDump(attempt.id);
      if (current == null) {
        throw StateError('Dump disappeared: ${attempt.id}');
      }
      return current;
    } catch (cause) {
      if (cause is _TranscriptionPersistenceFailure) rethrow;
      throw _TranscriptionPersistenceFailure(cause);
    }
  }

  Future<void> _persistRecoverable(
    DumpRow attempt, {
    required String marker,
    String? jobId,
  }) async {
    final cached = _durableRows[attempt.id] ?? attempt;
    final cachedStatus =
        TranscriptionStatus.fromWire(cached.transcriptionStatus);
    final status = cachedStatus.isInProgress
        ? cachedStatus
        : jobId == null
            ? TranscriptionStatus.uploading
            : TranscriptionStatus.queued;
    try {
      await _db.updateTranscriptionStatus(
        attempt.id,
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        status: status,
        now: _now(),
        jobId: jobId,
        error: marker,
      );
    } catch (_) {
      // The request/job identity already persisted before this best-effort
      // marker. A later coordinator can reconcile it when SQLite is healthy.
    }
  }

  Future<void> _refreshDurableRow(String dumpId) async {
    try {
      final latest = await _db.getDump(dumpId);
      if (latest != null) _durableRows[dumpId] = latest;
    } catch (_) {
      // Preserve the last known durable snapshot if SQLite is unavailable.
    }
  }

  bool _isAmbiguousEnqueueFailure(Object error) {
    if (error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is HandshakeException ||
        error is FormatException) {
      return true;
    }
    if (error is! DioException) return false;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown =>
        true,
      _ => false,
    };
  }

  bool _isDefinitiveFailure(Object error) {
    return error is LocalTranscriptionServerError ||
        _isDefinitiveEnqueueRejection(error);
  }

  /// Returns true only when an HTTP response proves this request did not
  /// create or match a server job. Every other enqueue response is ambiguous:
  /// the server may have committed the idempotent job before the response was
  /// replaced, delayed, or rejected by an intermediary.
  bool _isDefinitiveEnqueueRejection(Object error) {
    int? statusCode;
    String? code;
    if (error is ApiException) {
      statusCode = error.statusCode;
      code = error.code;
    } else if (error is DioException &&
        error.type == DioExceptionType.badResponse) {
      statusCode = error.response?.statusCode;
      final data = error.response?.data;
      if (data is Map) {
        final apiError = data['error'];
        if (apiError is Map) code = apiError['code']?.toString();
        code ??= data['code']?.toString();
      }
    } else {
      return false;
    }

    if (statusCode == 409) return code == 'request_id_conflict';
    return statusCode == 400 ||
        statusCode == 401 ||
        statusCode == 403 ||
        statusCode == 404 ||
        statusCode == 413 ||
        statusCode == 422;
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

final class _StaleTranscriptionAttempt implements Exception {
  const _StaleTranscriptionAttempt();
}

final class _ExistingDurableTranscription implements Exception {
  const _ExistingDurableTranscription();
}

final class _RecoverableTranscriptionAttempt implements Exception {
  const _RecoverableTranscriptionAttempt(this.marker);
  final String marker;
}

final class _TranscriptionPersistenceFailure implements Exception {
  const _TranscriptionPersistenceFailure(this.cause);
  final Object cause;
}

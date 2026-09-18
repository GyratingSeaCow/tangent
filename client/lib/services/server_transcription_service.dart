// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/storage/storage_contract.dart';
import 'retained_future_io.dart';
import '../data/local_db.dart';
import '../data/manual_transcript_publication.dart';
import '../data/recording_metadata.dart';
import '../models/api_exception.dart';
import '../models/transcription_status.dart';
import 'meeting_notes_processor.dart';
import 'meeting_transcript_formatter.dart';
import 'transcription_client.dart';

/// Durable coordinator for server-side transcription.
///
/// The server owns execution and SQLite owns presentation state. This service
/// serializes local starts, persists ownership before network I/O, and repairs
/// interrupted attempts without exposing a second in-memory status model.

final class _QueuedTranscription {
  _QueuedTranscription(this.dumpId, {this.recoveryOnly = false});
  final String dumpId;
  bool recoveryOnly;
  late final Future<void> ready;
  DumpRow? ownedRow;
  UseLease? use;
  Object? preparationError;
  final Completer<void> completer = Completer<void>();
}

final class _OwnedJobEventStream {
  _OwnedJobEventStream(Stream<JobEvent> stream)
      : iterator = StreamIterator<JobEvent>(stream);

  final StreamIterator<JobEvent> iterator;
  Future<void>? _cancellation;

  Future<void> cancel() => _cancellation ??= _cancel();

  Future<void> _cancel() async {
    try {
      await iterator.cancel();
    } catch (_) {
      // Cancellation is best-effort during synchronous service disposal.
    }
  }
}

class ServerTranscriptionService extends ChangeNotifier {
  ServerTranscriptionService({
    required TranscriptionClient client,
    required LocalDb db,
    required RecordingAccess recordingAccess,
    required RecordingMutationCoordinator mutations,
    MeetingNotesProcessor meetingNotesProcessor = const MeetingNotesProcessor(),
    String Function()? requestIdFactory,
    DateTime Function()? now,
    Future<void> Function(BoundRecording, Map<String, dynamic>)? metadataWriter,
    Duration recoveryRequestTimeout = const Duration(seconds: 30),
    Duration operationRequestTimeout = const Duration(seconds: 30),
    Duration sidecarWaitTimeout = const Duration(seconds: 30),
    Duration recoveryRetryBaseDelay = const Duration(seconds: 1),
    Duration recoveryRetryMaxDelay = const Duration(seconds: 30),
  })  : _client = client,
        _db = db,
        _access = recordingAccess,
        _mutations = mutations,
        _meetingNotesProcessor = meetingNotesProcessor,
        _requestIdFactory = requestIdFactory ?? const Uuid().v4,
        _now = now ?? (() => DateTime.now().toUtc()),
        _metadataWriterOverride = metadataWriter,
        _recoveryRequestTimeout = recoveryRequestTimeout,
        _operationRequestTimeout = operationRequestTimeout,
        _sidecarWaitTimeout = sidecarWaitTimeout,
        _recoveryRetryBaseDelay = recoveryRetryBaseDelay,
        _recoveryRetryMaxDelay = recoveryRetryMaxDelay;

  final TranscriptionClient _client;
  final LocalDb _db;
  final RecordingAccess _access;
  final RecordingMutationCoordinator _mutations;
  int _transportSequence = 0;
  final MeetingNotesProcessor _meetingNotesProcessor;
  final String Function() _requestIdFactory;
  final DateTime Function() _now;
  final Future<void> Function(BoundRecording, Map<String, dynamic>)?
      _metadataWriterOverride;
  final Duration _recoveryRequestTimeout;
  final Duration _operationRequestTimeout;
  final Duration _sidecarWaitTimeout;
  final Duration _recoveryRetryBaseDelay;
  final Duration _recoveryRetryMaxDelay;

  final List<_QueuedTranscription> _queue = [];
  final Map<String, DumpRow> _durableRows = {};
  final Map<String, _OwnedJobEventStream> _reattachments = {};
  final Set<String> _resolvingRecoveryDumpIds = {};
  final Set<String> _pendingLocalReattachmentHandoffs = {};
  final Set<String> _pendingReattachmentHandoffs = {};
  final Map<String, int> _recoveryRetryAttempts = {};
  final Map<String, Timer> _recoveryRetryTimers = {};
  Future<void>? _reconciliationScan;
  int _requestedReconciliationGeneration = 0;
  int _processedReconciliationGeneration = 0;
  _QueuedTranscription? _activeJob;
  _OwnedJobEventStream? _activeStream;
  bool _disposed = false;

  List<String> get queuedDumpIds =>
      List.unmodifiable(_queue.map((job) => job.dumpId));

  /// The dump currently being transcribed, or null when nothing is running.
  ///
  /// Exposed so the notification layer can report progress without reaching
  /// into the queue: "is anything running?" and "how many are waiting?" are
  /// the only two questions the shade asks.
  String? get activeDumpId => _activeJob?.dumpId;

  /// True while a job is actually executing — not merely accepted.
  bool get isTranscribing => _activeJob != null;

  bool _forceRecoveryScan = false;

  /// Durable commits are signals, never new attempts. The app-scoped observer
  /// targets the current instance; disposal never resumes network execution.
  void durableRecoveryChanged(Iterable<String> dumpIds) {
    if (_disposed) return;
    for (final id in dumpIds) {
      if (_isLocallyOwned(id)) {
        // Do not reclassify a fresh local acceptance as recovery-only when its
        // transaction is observed before its Future returns.
        _pendingLocalReattachmentHandoffs.add(id);
      } else if (_reattachments.containsKey(id)) {
        _pendingReattachmentHandoffs.add(id);
      } else {
        _scheduleRecoveryRetry(id);
      }
    }
  }

  Future<void> reconcilePending() => _requestReconciliation();

  Future<void> _requestReconciliation({bool respectRetryBackoff = false}) {
    if (_disposed) return Future<void>.value();
    _forceRecoveryScan |= !respectRetryBackoff;
    _requestedReconciliationGeneration += 1;
    final activeScan = _reconciliationScan;
    if (activeScan != null) return activeScan;

    final completer = Completer<void>();
    final scan = completer.future;
    _reconciliationScan = scan;
    scheduleMicrotask(() {
      unawaited(_drainReconciliationGenerations(completer, scan));
    });
    return scan;
  }

  Future<void> _drainReconciliationGenerations(
    Completer<void> completer,
    Future<void> scan,
  ) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      while (!_disposed &&
          _processedReconciliationGeneration <
              _requestedReconciliationGeneration) {
        final generation = _requestedReconciliationGeneration;
        final force = _forceRecoveryScan;
        _forceRecoveryScan = false;
        await _scanPending(respectRetryBackoff: !force);
        _processedReconciliationGeneration = generation;
      }
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }

    if (identical(_reconciliationScan, scan)) _reconciliationScan = null;
    if (failure == null) {
      completer.complete();
    } else {
      completer.completeError(failure, failureStack!);
    }
  }

  void _scheduleRecoveryRetry(String dumpId) {
    if (_disposed || _recoveryRetryTimers.containsKey(dumpId)) return;
    final attempt = _recoveryRetryAttempts[dumpId] ?? 0;
    _recoveryRetryAttempts[dumpId] = attempt + 1;
    var delay = Duration.zero;
    if (attempt > 0) {
      delay = _recoveryRetryBaseDelay;
      for (var i = 1; i < attempt; i += 1) {
        final doubled = delay * 2;
        if (doubled.compareTo(_recoveryRetryMaxDelay) >= 0) {
          delay = _recoveryRetryMaxDelay;
          break;
        }
        delay = doubled;
      }
      if (delay.compareTo(_recoveryRetryMaxDelay) > 0) {
        delay = _recoveryRetryMaxDelay;
      }
    }
    late final Timer timer;
    timer = Timer(delay, () {
      if (identical(_recoveryRetryTimers[dumpId], timer)) {
        _recoveryRetryTimers.remove(dumpId);
      }
      if (!_disposed) {
        unawaited(_requestReconciliation(respectRetryBackoff: true));
      }
    });
    _recoveryRetryTimers[dumpId] = timer;
  }

  void _clearRecoveryRetry(String dumpId) {
    _recoveryRetryTimers.remove(dumpId)?.cancel();
    _recoveryRetryAttempts.remove(dumpId);
  }

  void _clearRecoveryRetryIfTerminal(String dumpId) {
    final row = _durableRows[dumpId];
    if (row == null) return;
    if (!TranscriptionStatus.fromWire(row.transcriptionStatus).isInProgress) {
      _clearRecoveryRetry(dumpId);
    }
  }

  Future<void> _scanPending({required bool respectRetryBackoff}) async {
    if (_disposed) return;
    late final List<DumpRow> rows;
    try {
      rows = await _db.dumpsNeedingTranscriptionRecovery();
    } catch (_) {
      return;
    }
    if (_disposed) return;
    await Future.wait(
      rows.map((row) async {
        try {
          if (_disposed) return;
          // Another row's signal/timer must not accelerate this row's backoff.
          // Explicit startup/resume scans may still force reconciliation.
          if (respectRetryBackoff && _recoveryRetryTimers.containsKey(row.id)) {
            return;
          }
          if (_isLocallyOwned(row.id)) {
            _markLocalRecoveryHandoff(row.id);
            return;
          }
          _resolvingRecoveryDumpIds.add(row.id);
          UseLease? use;
          var transferred = false;
          try {
            use = switch (await _mutations.acquire(row.id, UseKind.recovery)) {
              Ok<UseLease>(:final value) => value,
              Fail<UseLease>(:final problem) => throw StorageFault(problem),
            };
            final current = await _db.getDump(row.id);
            if (current == null) return;
            final attachment = await _resolvePendingRow(use, current);
            if (_disposed) return;
            if (attachment == null) {
              final current = _durableRows[row.id] ?? row;
              if (TranscriptionStatus.fromWire(current.transcriptionStatus)
                      .isInProgress ||
                  (current.transcriptionError
                          ?.startsWith('sidecar_sync_pending:') ??
                      false)) {
                _scheduleRecoveryRetry(row.id);
              } else {
                _clearRecoveryRetry(row.id);
              }
              return;
            }
            final (attachmentRow, jobId) = attachment;
            transferred = _startReattachment(use, attachmentRow, jobId);
          } finally {
            if (!transferred && use != null) unawaited(use.close());
            _resolvingRecoveryDumpIds.remove(row.id);
          }
        } on _ServiceDisposed {
          // Provider replacement owns all work after this scan was disposed.
        } catch (_) {
          // Each row is isolated so failed error recording cannot reject the scan.
        }
      }),
    );
  }

  Future<(DumpRow, String)?> _resolvePendingRow(
    UseLease use,
    DumpRow row,
  ) async {
    try {
      _throwIfDisposed();
      if (TranscriptionStatus.fromWire(row.transcriptionStatus).isTerminal &&
          (row.transcriptionError?.startsWith('sidecar_sync_pending:') ??
              false)) {
        await _repairCompletedSidecar(use, row);
        _throwIfDisposed();
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
          _throwIfDisposed();
          try {
            snapshot = await _awaitRecoveryRequest(
              use,
              () => _client.enqueueTranscription(
                row.id,
                requestId: requestId,
                model: 'large-v3',
              ),
            );
            _throwIfDisposed();
            break;
          } on ApiException catch (error) {
            _throwIfDisposed();
            if (error.statusCode == 404 && !repairedMetadata) {
              repairedMetadata = true;
              await _awaitRecoveryRequest(
                use,
                () => _client.createDump(
                  id: row.id,
                  mode: row.mode,
                  durationSeconds: row.durationSeconds,
                  title: row.title,
                  createdAt: row.createdAt,
                ),
              );
              _throwIfDisposed();
              continue;
            }
            if (error.statusCode == 422 &&
                error.code == 'missing_audio' &&
                !repairedAudio) {
              repairedAudio = true;
              late final List<int> audioBytes;
              try {
                audioBytes = await _readAudio(use);
              } catch (error) {
                _throwIfDisposed();
                throw LocalTranscriptionServerError(
                  'Failed to read durable audio: $error',
                );
              }
              _throwIfDisposed();
              if (audioBytes.isEmpty) {
                throw const LocalTranscriptionServerError(
                  'Audio file is empty',
                );
              }
              await _awaitRecoveryRequest(
                use,
                () => _client.uploadAudio(
                  dumpId: row.id,
                  audioBytes: audioBytes,
                ),
              );
              _throwIfDisposed();
              continue;
            }
            rethrow;
          }
        }
        if (snapshot.status == 'completed') {
          final accepted = await _guardedStatus(
            use,
            row,
            status: TranscriptionStatus.queued,
            jobId: snapshot.id,
          );
          _throwIfDisposed();
          if (!accepted) return null;
          final transcript = snapshot.transcript?.trim();
          if (transcript == null || transcript.isEmpty) {
            await _guardedStatus(
              use,
              row,
              status: TranscriptionStatus.failed,
              jobId: snapshot.id,
              error: 'Server returned an empty transcript',
            );
            _throwIfDisposed();
          } else {
            await _persistRecoveredCompletion(
              use,
              row,
              _presentedTranscript(row, transcript, snapshot.segments),
            );
            _throwIfDisposed();
          }
          await _refreshDurableRow(row.id);
          _throwIfDisposed();
          return null;
        }
        if (snapshot.status == 'failed') {
          await _guardedStatus(
            use,
            row,
            status: TranscriptionStatus.failed,
            jobId: snapshot.id,
            error: snapshot.error ?? 'Server job failed',
          );
          _throwIfDisposed();
          await _refreshDurableRow(row.id);
          _throwIfDisposed();
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
            await _guardedStatus(use, row, status: status, jobId: snapshot.id);
        _throwIfDisposed();
        await _refreshDurableRow(row.id);
        _throwIfDisposed();
        return accepted ? (row, snapshot.id) : null;
      }
      final snapshot =
          await _awaitRecoveryRequest(use, () => _client.getJob(jobId));
      _throwIfDisposed();
      if (snapshot.status == 'failed') {
        await _guardedStatus(
          use,
          row,
          status: TranscriptionStatus.failed,
          jobId: jobId,
          error: snapshot.error ?? 'Server job failed',
        );
        _throwIfDisposed();
        await _refreshDurableRow(row.id);
        _throwIfDisposed();
        return null;
      }
      if (snapshot.status != 'completed') {
        final status = switch (snapshot.status) {
          'running' => TranscriptionStatus.running,
          'queued' => TranscriptionStatus.queued,
          _ => throw FormatException(
              'Unknown transcription status: ${snapshot.status}',
            ),
        };
        final accepted =
            await _guardedStatus(use, row, status: status, jobId: jobId);
        _throwIfDisposed();
        if (!accepted) return null;
        await _refreshDurableRow(row.id);
        _throwIfDisposed();
        return (row, jobId);
      }
      final transcript = snapshot.transcript?.trim();
      if (transcript == null || transcript.isEmpty) {
        await _guardedStatus(
          use,
          row,
          status: TranscriptionStatus.failed,
          jobId: jobId,
          error: 'Server returned an empty transcript',
        );
        _throwIfDisposed();
        await _refreshDurableRow(row.id);
        _throwIfDisposed();
        return null;
      }
      await _persistRecoveredCompletion(
        use,
        row,
        _presentedTranscript(row, transcript, snapshot.segments),
      );
      _throwIfDisposed();
    } on _ServiceDisposed {
      return null;
    } catch (error) {
      if (_disposed) return null;
      if (!TranscriptionStatus.fromWire(row.transcriptionStatus).isTerminal) {
        if (_isDefinitiveFailure(error)) {
          await _guardedStatus(
            use,
            row,
            status: TranscriptionStatus.failed,
            jobId: row.transcriptionJobId,
            error: error.toString(),
          );
          _throwIfDisposed();
        } else {
          await _persistRecoverable(
            use,
            row,
            marker: 'reconciliation_pending: $error',
            jobId: row.transcriptionJobId,
          );
          _throwIfDisposed();
        }
      }
      await _refreshDurableRow(row.id);
      _throwIfDisposed();
    }
    return null;
  }

  Future<T> _transport<T>(
    UseLease use,
    Future<T> Function() start,
    Duration timeout,
  ) async {
    _throwIfDisposed();
    if (!await _db.mutationAllowed(use.key)) {
      throw const StorageFault(
        (
          code: ProblemCode.wrongIncarnation,
          message: 'Captured transcription recording is no longer available'
        ),
      );
    }
    _throwIfDisposed();
    return _mutations
        .runIo(
          use,
          () => RetainedFutureIo(
            'transcription-${_transportSequence++}',
            start,
          ),
        )
        .timeout(timeout);
  }

  Future<T> _awaitRecoveryRequest<T>(
    UseLease use,
    Future<T> Function() start,
  ) =>
      _transport(use, start, _recoveryRequestTimeout);

  Future<T> _awaitOperationRequest<T>(
    UseLease use,
    Future<T> Function() start,
  ) =>
      _transport(use, start, _operationRequestTimeout);

  Future<List<int>> _readAudio(UseLease use) async {
    final audio = switch (await _access.openAudio(use.key)) {
      Ok<AudioReadLease>(:final value) => value,
      Fail<AudioReadLease>(:final problem) => throw StorageFault(problem),
    };
    try {
      return await audio.read();
    } finally {
      await audio.close();
    }
  }

  Future<void> _awaitSidecarWrite(Future<void> write) {
    return write.timeout(_sidecarWaitTimeout, onTimeout: () {});
  }

  bool _startReattachment(UseLease use, DumpRow row, String jobId) {
    if (_disposed) return false;
    if (_isLocallyOwned(row.id)) {
      _markLocalRecoveryHandoff(row.id);
      return false;
    }
    if (_reattachments.containsKey(row.id)) {
      _pendingReattachmentHandoffs.add(row.id);
      return false;
    }
    final attachment = _OwnedJobEventStream(_client.streamJob(jobId));
    _reattachments[row.id] = attachment;
    final watcher =
        _watchReattachedJob(use, row, jobId, attachment).whenComplete(() async {
      var releasedOwnership = false;
      if (identical(_reattachments[row.id], attachment)) {
        _reattachments.remove(row.id);
        releasedOwnership = true;
      }
      await attachment.cancel();
      unawaited(use.close());
      _clearRecoveryRetryIfTerminal(row.id);
      if (releasedOwnership &&
          _pendingReattachmentHandoffs.remove(row.id) &&
          !_disposed) {
        _scheduleRecoveryRetry(row.id);
      }
    });
    unawaited(watcher);
    return true;
  }

  Future<void> _watchReattachedJob(
    UseLease use,
    DumpRow row,
    String jobId,
    _OwnedJobEventStream attachment,
  ) async {
    try {
      while (await attachment.iterator.moveNext()) {
        if (_disposed) return;
        final event = attachment.iterator.current;
        switch (event.status) {
          case 'queued':
            break;
          case 'running':
            final runningWon = await _guardedStatus(
              use,
              row,
              status: TranscriptionStatus.running,
              jobId: jobId,
            );
            _throwIfDisposed();
            if (!runningWon) return;
            await _refreshDurableRow(row.id);
            _throwIfDisposed();
          case 'completed':
            final transcript = event.data['transcript']?.toString().trim();
            if (transcript == null || transcript.isEmpty) {
              await _guardedStatus(
                use,
                row,
                status: TranscriptionStatus.failed,
                jobId: jobId,
                error: 'Server returned an empty transcript',
              );
              await _refreshDurableRow(row.id);
            } else {
              await _persistRecoveredCompletion(
                use,
                row,
                _presentedTranscript(
                  row,
                  transcript,
                  parseTranscriptSegments(event.data['segments']),
                ),
              );
            }
            return;
          case 'failed':
            await _guardedStatus(
              use,
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
              use,
              row,
              jobId,
              event.data['error']?.toString() ??
                  event.data['message']?.toString() ??
                  'Server stream reported ${event.status}',
            );
            return;
          default:
            break;
        }
      }
      if (_disposed) return;
      await _storeReattachmentError(
        use,
        row,
        jobId,
        'Event stream ended before a terminal event',
      );
    } catch (error) {
      if (_disposed) return;
      await _storeReattachmentError(use, row, jobId, error.toString());
    }
  }

  Future<void> _storeReattachmentError(
    UseLease use,
    DumpRow row,
    String jobId,
    String error,
  ) async {
    try {
      if (_disposed) return;
      await _persistRecoverable(
        use,
        row,
        marker: 'reconciliation_pending: $error',
        jobId: jobId,
      );
      await _refreshDurableRow(row.id);
    } finally {
      if (!_disposed) _scheduleRecoveryRetry(row.id);
    }
  }

  Future<void> _persistRecoveredCompletion(
    UseLease use,
    DumpRow row,
    String transcript,
  ) async {
    _throwIfDisposed();
    final meetingNotes = _meetingNotesForCompletion(row, transcript);
    final completed = await _db.completeTranscriptionAttempt(
      row.id,
      storageKey: use.key,
      attempt: row.transcriptionAttempt,
      requestId: row.transcriptionRequestId!,
      transcript: transcript,
      meetingNotes: meetingNotes,
      now: _now(),
      sidecarError: 'sidecar_sync_pending: write pending',
    );
    _throwIfDisposed();
    if (!completed) return;
    final committed = await _db.getDump(row.id);
    _throwIfDisposed();
    if (committed == null) return;
    _durableRows[row.id] = committed;
    await _repairCompletedSidecar(use, committed);
    _throwIfDisposed();
  }

  /// The transcript text a dump actually stores.
  ///
  /// Meeting dumps present diarised results as timestamped speaker blocks; the
  /// formatted string IS the transcript, so editing, sidecar publication, and
  /// notes generation all continue to work on one unchanged column. Every
  /// other mode, and any meeting result the server sent without usable
  /// segments, keeps the plain server text exactly as before.
  String _presentedTranscript(
    DumpRow row,
    String transcript,
    List<TranscriptSegment> segments,
  ) {
    if (row.mode != 'meeting' || segments.isEmpty) return transcript;
    final formatted = formatMeetingTranscript(segments);
    if (formatted == null || formatted.trim().isEmpty) return transcript;
    return formatted;
  }

  String? _meetingNotesForCompletion(DumpRow row, String transcript) {
    if (row.mode != 'meeting') return null;
    final isReplacement = row.transcript?.trim().isNotEmpty ?? false;
    if (isReplacement) return row.meetingNotes;
    return _meetingNotesProcessor.process(
      title: row.title,
      transcript: transcript,
    );
  }

  Future<void> _repairCompletedSidecar(UseLease use, DumpRow row) async {
    _throwIfDisposed();
    if (row.transcriptionError
            ?.startsWith('sidecar_sync_pending: manual_edit:') ??
        false) {
      await _awaitSidecarWrite(
        publishManualTranscriptSidecar(
          db: _db,
          access: _access,
          storageKey: use.key,
          revision: row,
          now: _now,
          checkActive: _throwIfDisposed,
          metadataWriter: _metadataWriterOverride,
        ).then<void>((_) {}),
      );
      _throwIfDisposed();
      await _refreshDurableRow(row.id);
      _throwIfDisposed();
      return;
    }
    await _awaitSidecarWrite(
      _access.runSerializedMetadataWrite<void>(
        use.key,
        (writer) async {
          _throwIfDisposed();
          final current = await _db.getDump(row.id);
          _throwIfDisposed();
          if (current == null ||
              current.transcriptionAttempt != row.transcriptionAttempt ||
              current.transcriptionRequestId != row.transcriptionRequestId ||
              !TranscriptionStatus.fromWire(current.transcriptionStatus)
                  .isTerminal ||
              !(current.transcriptionError
                      ?.startsWith('sidecar_sync_pending:') ??
                  false)) {
            return;
          }
          final restoredError =
              LocalDb.errorAfterSidecarSync(current.transcriptionError);
          final metadata = dumpMetadata(current)
            ..['transcriptionError'] = restoredError;
          final override = _metadataWriterOverride;
          if (override == null) {
            await writer.write(metadata);
          } else {
            await override(writer.binding, metadata);
          }
          _throwIfDisposed();
          await _db.updateTranscriptionSidecarError(
            current.id,
            storageKey: writer.binding.key,
            attempt: current.transcriptionAttempt,
            requestId: current.transcriptionRequestId,
            error: restoredError,
            expectedTranscript: current.transcript,
            expectedError: current.transcriptionError,
            now: _now(),
          );
          _throwIfDisposed();
          await _refreshDurableRow(current.id);
          _throwIfDisposed();
        },
      ),
    );
    _throwIfDisposed();
  }

  bool _isLocallyOwned(String dumpId) {
    return _activeJob?.dumpId == dumpId ||
        _queue.any((job) => job.dumpId == dumpId);
  }

  void _markLocalRecoveryHandoff(String dumpId) {
    _pendingLocalReattachmentHandoffs.add(dumpId);
    final active = _activeJob;
    if (active?.dumpId == dumpId && active?.ownedRow == null) {
      active!.recoveryOnly = true;
    }
    for (final queued in _queue) {
      if (queued.dumpId == dumpId && queued.ownedRow == null) {
        queued.recoveryOnly = true;
      }
    }
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

    final job = _QueuedTranscription(
      dumpId,
      recoveryOnly: _resolvingRecoveryDumpIds.contains(dumpId),
    );
    _queue.add(job);
    job.ready = _prepareOwnership(job);
    _notify();
    _startNext();
    return job.completer.future;
  }

  Future<void> _prepareOwnership(_QueuedTranscription job) async {
    try {
      if (job.recoveryOnly) return;
      job.use =
          switch (await _mutations.acquire(job.dumpId, UseKind.acceptance)) {
        Ok<UseLease>(:final value) => value,
        Fail<UseLease>(:final problem) when problem.code == ProblemCode.busy =>
          throw const _ExistingDurableTranscription(),
        Fail<UseLease>(:final problem) => throw StorageFault(problem),
      };
      final existing = await _db.getDump(job.dumpId);
      if (existing == null) {
        throw const LocalTranscriptionServerError('Dump not found');
      }
      if (job.recoveryOnly) return;
      // Notes are terminally not_applicable: this service must never upload
      // a text note's .md bytes as audio, regardless of how it was reached.
      if (existing.mode == 'text_note' ||
          existing.transcriptionStatus ==
              TranscriptionStatus.notApplicable.wireValue) {
        throw const LocalTranscriptionServerError(
          'Text notes cannot be transcribed',
        );
      }
      if (TranscriptionStatus.fromWire(existing.transcriptionStatus)
          .isInProgress) {
        throw const _ExistingDurableTranscription();
      }
      // Acceptance is independent of FIFO activation. Even disposal while this
      // transaction is pending must not silently discard the accepted action.
      job.ownedRow = await _db.beginTranscriptionAttempt(
        job.dumpId,
        storageKey: job.use!.key,
        requestId: _requestIdFactory(),
        now: _now(),
      );
    } catch (error) {
      job.preparationError = error;
    }
  }

  void _startNext() {
    if (_disposed || _activeJob != null || _queue.isEmpty) return;
    final job = _queue.removeAt(0);
    _activeJob = job;
    unawaited(_run(job));
  }

  Future<void> _run(_QueuedTranscription job) async {
    final dumpId = job.dumpId;
    _notify();

    DumpRow? attemptRow;
    String? remoteJobId;
    var foundExistingAttempt = false;
    var recoverableExit = false;
    late final UseLease use;
    try {
      await job.ready;
      _throwIfDisposed();
      if (job.preparationError != null) throw job.preparationError!;
      final row = job.ownedRow;
      if (row == null) return;
      use = job.use!;
      _clearRecoveryRetry(dumpId);
      attemptRow = row;
      _durableRows[row.id] = row;
      final audioBytes = await _readAudio(use);
      _throwIfDisposed();
      if (audioBytes.isEmpty) {
        throw const LocalTranscriptionServerError('Audio file is empty');
      }

      // Ensure the server has the dump metadata + audio. The server is
      // idempotent on `id`, so re-sending is safe even when a previous
      // sync already uploaded the audio but transcription failed.
      await _awaitOperationRequest(
        use,
        () => _client.createDump(
          id: row.id,
          mode: row.mode,
          durationSeconds: row.durationSeconds,
          title: row.title,
          createdAt: row.createdAt,
        ),
      );
      _throwIfDisposed();
      await _awaitOperationRequest(
        use,
        () => _client.uploadAudio(
          dumpId: row.id,
          audioBytes: audioBytes,
        ),
      );
      _throwIfDisposed();

      _notify();

      final TranscriptionJobSnapshot enqueuedJob;
      try {
        enqueuedJob = await _awaitOperationRequest(
          use,
          () => _client.enqueueTranscription(
            row.id,
            requestId: row.transcriptionRequestId!,
          ),
        );
        _throwIfDisposed();
      } catch (error) {
        _throwIfDisposed();
        if (_isDefinitiveEnqueueRejection(error)) rethrow;
        final marker = 'enqueue_pending: $error';
        await _guardedStatus(
          use,
          row,
          status: TranscriptionStatus.uploading,
          error: marker,
        );
        throw _RecoverableTranscriptionAttempt(marker);
      }
      remoteJobId = enqueuedJob.id;
      final queuedWon = await _guardedStatus(
        use,
        row,
        status: TranscriptionStatus.queued,
        jobId: enqueuedJob.id,
      );
      _throwIfDisposed();
      if (!queuedWon) throw const _StaleTranscriptionAttempt();
      _durableRows[row.id] = await _readCurrentAttempt(row);
      _throwIfDisposed();
      String? transcript;
      var segments = const <TranscriptSegment>[];
      var sawCompleted = false;
      final activeStream =
          _OwnedJobEventStream(_client.streamJob(enqueuedJob.id));
      _activeStream = activeStream;
      try {
        while (await activeStream.iterator.moveNext()) {
          if (_disposed) throw const _ServiceDisposed();
          final event = activeStream.iterator.current;
          switch (event.status) {
            case 'queued':
              // Server confirmed queue position; no action needed.
              break;
            case 'running':
              final runningWon = await _guardedStatus(
                use,
                row,
                status: TranscriptionStatus.running,
                jobId: enqueuedJob.id,
              );
              _throwIfDisposed();
              if (!runningWon) throw const _StaleTranscriptionAttempt();
              _durableRows[row.id] = await _readCurrentAttempt(row);
              _throwIfDisposed();
              _notify();
            case 'completed':
              sawCompleted = true;
              transcript = event.data['transcript']?.toString().trim() ?? '';
              segments = parseTranscriptSegments(event.data['segments']);
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
      } finally {
        if (identical(_activeStream, activeStream)) _activeStream = null;
        await activeStream.cancel();
      }

      if (_disposed) throw const _ServiceDisposed();
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

      final stored = _presentedTranscript(row, transcript, segments);
      final meetingNotes = _meetingNotesForCompletion(row, stored);
      bool completionWon;
      try {
        completionWon = await _db.completeTranscriptionAttempt(
          row.id,
          storageKey: use.key,
          attempt: row.transcriptionAttempt,
          requestId: row.transcriptionRequestId!,
          transcript: stored,
          meetingNotes: meetingNotes,
          now: _now(),
          sidecarError: 'sidecar_sync_pending: write pending',
        );
      } catch (cause) {
        throw _TranscriptionPersistenceFailure(cause);
      }
      _throwIfDisposed();
      if (!completionWon) throw const _StaleTranscriptionAttempt();
      await _awaitSidecarWrite(
        _access.runSerializedMetadataWrite<void>(
          use.key,
          (writer) async {
            final completed = await _readCurrentAttempt(row);
            if (completed.transcriptionAttempt != row.transcriptionAttempt ||
                completed.transcriptionRequestId !=
                    row.transcriptionRequestId ||
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
                await writer.write(sidecarMetadata);
              } else {
                await override(writer.binding, sidecarMetadata);
              }
            } catch (error) {
              try {
                await _db.updateTranscriptionSidecarError(
                  completed.id,
                  storageKey: writer.binding.key,
                  attempt: completed.transcriptionAttempt,
                  requestId: completed.transcriptionRequestId!,
                  error: 'sidecar_sync_pending: $error',
                  expectedTranscript: completed.transcript,
                  expectedError: completed.transcriptionError,
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
                storageKey: writer.binding.key,
                attempt: completed.transcriptionAttempt,
                requestId: completed.transcriptionRequestId!,
                error: null,
                expectedTranscript: completed.transcript,
                expectedError: completed.transcriptionError,
                now: _now(),
              );
              if (!cleared) throw const _StaleTranscriptionAttempt();
            } on _StaleTranscriptionAttempt {
              rethrow;
            } catch (cause) {
              throw _TranscriptionPersistenceFailure(cause);
            }
          },
        ),
      );
    } on _ServiceDisposed {
      // Provider replacement only detaches this observer. The durable request
      // identity remains available for the replacement service to reconcile.
    } on _RecoverableTranscriptionAttempt catch (recoverable) {
      recoverableExit = true;
      if (!_disposed && attemptRow != null) {
        await _persistRecoverable(
          use,
          attemptRow,
          marker: recoverable.marker,
          jobId: remoteJobId,
        );
      }
    } on _TranscriptionPersistenceFailure {
      recoverableExit = true;
      // Never convert a SQLite failure into a definitive remote-job failure.
      // The durable request/job identity remains eligible for reconciliation.
    } on _StaleTranscriptionAttempt {
      // A newer attempt owns the row; this flow must not touch it.
    } on _ExistingDurableTranscription {
      // Another coordinator already owns the durable attempt.
      foundExistingAttempt = true;
    } catch (error) {
      if (!_disposed && attemptRow != null) {
        final postEnqueueUncertain =
            remoteJobId != null && !_isDefinitiveFailure(error);
        if (postEnqueueUncertain || _isAmbiguousEnqueueFailure(error)) {
          recoverableExit = true;
          await _persistRecoverable(
            use,
            attemptRow,
            marker: 'reconciliation_pending: $error',
            jobId: remoteJobId,
          );
        } else {
          try {
            await _guardedStatus(
              use,
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
      if (!_disposed) {
        await _refreshDurableRow(dumpId);
        _clearRecoveryRetryIfTerminal(dumpId);
      }
      final hadPendingHandoff =
          _pendingLocalReattachmentHandoffs.remove(dumpId);
      final shouldReconcile = recoverableExit ||
          job.recoveryOnly ||
          foundExistingAttempt ||
          hadPendingHandoff;
      if (_activeJob == job) {
        _activeJob = null;
      }
      final owner = job.use;
      if (owner != null) unawaited(owner.close());
      if (!job.completer.isCompleted) job.completer.complete();
      _notify();
      _startNext();
      if (shouldReconcile && !_disposed) {
        _scheduleRecoveryRetry(dumpId);
      }
    }
  }

  /// Removes a not-yet-started local queue entry. Active work continues on
  /// the server because v1 has no cancellation endpoint. Recovery-owned rows
  /// are immediately handed back to reconciliation after queue removal.
  void cancel([String? dumpId]) {
    final target = dumpId;
    if (target == null || _activeJob?.dumpId == target) return;
    final index = _queue.indexWhere((job) => job.dumpId == target);
    if (index < 0) return;
    final removed = _queue.removeAt(index);
    final hadPendingHandoff = _pendingLocalReattachmentHandoffs.remove(target);
    final shouldReconcile = removed.recoveryOnly || hadPendingHandoff;
    unawaited(
      removed.ready.then((_) {
        final owner = removed.use;
        if (owner != null) unawaited(owner.close());
        if (!removed.completer.isCompleted) removed.completer.complete();
        if (!_disposed && (removed.ownedRow != null || shouldReconcile)) {
          _scheduleRecoveryRetry(target);
        }
      }),
    );
    _notify();
    if (shouldReconcile && !_disposed) {
      _scheduleRecoveryRetry(target);
    }
  }

  Future<bool> _guardedStatus(
    UseLease use,
    DumpRow attempt, {
    required TranscriptionStatus status,
    String? jobId,
    String? error,
  }) async {
    _throwIfDisposed();
    late final bool updated;
    try {
      updated = await _db.updateTranscriptionStatus(
        attempt.id,
        storageKey: use.key,
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
    _throwIfDisposed();
    return updated;
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
    UseLease use,
    DumpRow attempt, {
    required String marker,
    String? jobId,
  }) async {
    if (_disposed) return;
    final cached = _durableRows[attempt.id] ?? attempt;
    final cachedStatus =
        TranscriptionStatus.fromWire(cached.transcriptionStatus);
    final status = cachedStatus.isInProgress
        ? cachedStatus
        : jobId == null
            ? TranscriptionStatus.uploading
            : TranscriptionStatus.queued;
    if (_disposed) return;
    try {
      await _db.updateTranscriptionStatus(
        attempt.id,
        storageKey: use.key,
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
    if (_disposed) return;
    try {
      final latest = await _db.getDump(dumpId);
      if (_disposed) return;
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
    // Authentication failures do not prove that an already-created job failed
    // or that an idempotent enqueue was not committed. Keep the durable
    // identity so corrected credentials can reconcile the same request.
    return statusCode == 400 ||
        statusCode == 404 ||
        statusCode == 413 ||
        statusCode == 422;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _throwIfDisposed() {
    if (_disposed) throw const _ServiceDisposed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final activeStream = _activeStream;
    _activeStream = null;
    if (activeStream != null) unawaited(activeStream.cancel());
    final activeJob = _activeJob;
    if (activeJob != null) {
      unawaited(
        activeJob.ready.then((_) {
          if (!activeJob.completer.isCompleted) activeJob.completer.complete();
        }),
      );
    }
    final reattachments = _reattachments.values.toList();
    _reattachments.clear();
    _pendingLocalReattachmentHandoffs.clear();
    _pendingReattachmentHandoffs.clear();
    for (final timer in _recoveryRetryTimers.values) {
      timer.cancel();
    }
    _recoveryRetryTimers.clear();
    _recoveryRetryAttempts.clear();
    for (final attachment in reattachments) {
      unawaited(attachment.cancel());
    }
    for (final job in _queue) {
      unawaited(
        job.ready.then((_) {
          final owner = job.use;
          if (owner != null) unawaited(owner.close());
          if (!job.completer.isCompleted) job.completer.complete();
        }),
      );
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

final class _ServiceDisposed implements Exception {
  const _ServiceDisposed();
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

  @override
  String toString() => cause.toString();
}

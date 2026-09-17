// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:logger/logger.dart';
import '../data/storage/storage_contract.dart';
import '../data/local_db.dart';
import '../data/settings_store.dart';
import '../models/sync_status.dart';
import 'connectivity_service.dart';
import 'transcription_client.dart';
import 'retained_future_io.dart';

class SyncEngine {
  final LocalDb _db;
  final RecordingAccess _access;
  final RecordingMutationCoordinator _mutations;
  final TranscriptionClient _client;
  final ConnectivityService _connectivity;
  final SettingsStore _settings;
  final Logger _log = Logger();
  bool _syncing = false;
  bool _disposed = false;
  DateTime? _lastSync;
  String? _lastError;
  int _operation = 0;

  SyncEngine({
    required LocalDb db,
    required RecordingAccess recordingAccess,
    required RecordingMutationCoordinator mutations,
    required TranscriptionClient client,
    required ConnectivityService connectivity,
    required SettingsStore settings,
  })  : _db = db,
        _access = recordingAccess,
        _mutations = mutations,
        _client = client,
        _connectivity = connectivity,
        _settings = settings;

  bool get isSyncing => _syncing;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;
  void dispose() {
    _disposed = true;
  }

  Future<void> _check(UseLease lease) async {
    if (_disposed) throw StateError('SyncEngine is disposed');
    if (!await _db.mutationAllowed(lease.key)) {
      throw const StorageFault(
        (
          code: ProblemCode.wrongIncarnation,
          message: 'Captured sync recording is no longer available'
        ),
      );
    }
    if (_disposed) throw StateError('SyncEngine is disposed');
  }

  Future<T> _transport<T>(UseLease lease, Future<T> Function() start) async {
    await _check(lease);
    return _mutations.runIo(
      lease,
      () => RetainedFutureIo('sync-${_operation++}', start),
    );
  }

  Future<void> syncNow() async {
    if (_syncing || _disposed) return;
    _syncing = true;
    _lastError = null;
    try {
      final status = await _connectivity.currentStatus();
      if (_disposed || !status.isOnline) return;
      // Bulk upload is backup, and backup is opt-in. This gate is deliberately
      // separate from transcription: ServerTranscriptionService reaches the
      // self-hosted server on any connection (including cellular over
      // Tailscale) because the audio it sends IS the transcription request,
      // not a copy retained on the server for storage.
      if (_settings.keepRecordingsOnDeviceOnly) return;
      if (_settings.wifiOnlySync && status != ConnectivityStatus.wifi) return;
      final pending = await _db.dumpsNeedingUpload();
      for (final candidate in pending) {
        if (_disposed) return;
        UseLease? lease;
        DumpRow? row;
        try {
          lease =
              switch (await _mutations.acquire(candidate.id, UseKind.sync)) {
            Ok<UseLease>(:final value) => value,
            Fail<UseLease>(:final problem) => throw StorageFault(problem),
          };
          await _check(lease);
          row = await _db.getDump(candidate.id);
          // Recheck privacy after admission, not against the old pending snapshot.
          if (row == null ||
              row.mode == 'meeting' ||
              row.syncStatus == 'local_only' ||
              row.syncStatus == 'synced') {
            continue;
          }
          await _check(lease);
          // Text notes sync metadata only: the note body already travels in
          // the dump metadata, so the primary-content (.md) component is never
          // opened or uploaded.
          final isNote = row.mode == 'text_note';
          var audioBytes = const <int>[];
          if (!isNote) {
            final audio = switch (await _access.openAudio(lease.key)) {
              Ok<AudioReadLease>(:final value) => value,
              Fail<AudioReadLease>(:final problem) => throw StorageFault(problem),
            };
            try {
              audioBytes = await audio.read();
            } on StorageFault catch (error) {
              throw StorageFault(
                (
                  code: error.problem.code,
                  message:
                      'audio file missing or unreadable: ${error.problem.message}'
                ),
              );
            } finally {
              await audio.close();
            }
            if (audioBytes.isEmpty) throw StateError('audio file missing');
          }
          await _transport(
            lease,
            () => _client.createDump(
              id: row!.id,
              mode: row.mode,
              durationSeconds: row.durationSeconds,
              title: row.title,
              createdAt: row.createdAt,
            ),
          );
          if (!isNote) {
            await _transport(
              lease,
              () =>
                  _client.uploadAudio(dumpId: row!.id, audioBytes: audioBytes),
            );
          }
          await _check(lease);
          await _db.updateSyncStatus(
            row.id,
            SyncStatus.syncing,
            storageKey: lease.key,
          );
          await _check(lease);
          await _db.updateSyncStatus(
            row.id,
            SyncStatus.synced,
            storageKey: lease.key,
          );
          _log.i('uploaded ${row.id}');
        } catch (error, stack) {
          _lastError = error.toString();
          _log.e(
            'upload failed for ${candidate.id}',
            error: error,
            stackTrace: stack,
          );
          if (!_disposed &&
              lease != null &&
              row != null &&
              await _db.mutationAllowed(lease.key)) {
            await _db.updateSyncStatus(
              row.id,
              SyncStatus.failed,
              storageKey: lease.key,
              attempts: row.syncAttempts + 1,
              lastError: error.toString(),
            );
          }
        } finally {
          await lease?.close();
        }
      }
      if (!_disposed) _lastSync = DateTime.now();
    } catch (error, stack) {
      _log.e('sync error', error: error, stackTrace: stack);
      _lastError = error.toString();
    } finally {
      _syncing = false;
    }
  }
}

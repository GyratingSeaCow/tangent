// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import '../data/audio_storage.dart';
import '../data/local_db.dart';
import '../data/settings_store.dart';
import '../models/sync_status.dart';
import 'connectivity_service.dart';
import 'transcription_client.dart';

class SyncEngine {
  final LocalDb _db;
  final AudioStorage _audio;
  final TranscriptionClient _client;
  final ConnectivityService _connectivity;
  final SettingsStore _settings;
  final Logger _log = Logger();

  bool _syncing = false;
  DateTime? _lastSync;
  String? _lastError;

  SyncEngine({
    required LocalDb db,
    required AudioStorage audioStorage,
    required TranscriptionClient client,
    required ConnectivityService connectivity,
    required SettingsStore settings,
  })  : _db = db,
        _audio = audioStorage,
        _client = client,
        _connectivity = connectivity,
        _settings = settings;

  bool get isSyncing => _syncing;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;

  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    _lastError = null;
    try {
      final status = await _connectivity.currentStatus();
      if (!status.isOnline) {
        _log.i('sync skipped: offline');
        return;
      }
      if (_settings.wifiOnlySync && status != ConnectivityStatus.wifi) {
        _log.i('sync skipped: wifi-only');
        return;
      }

      final pending = await _db.dumpsNeedingUpload();
      _log.i('sync found ${pending.length} dumps');

      for (final row in pending) {
        try {
          final audioBytes =
              await _audio.readBytes(row.id).catchError((_) => Uint8List(0));
          if (audioBytes.isEmpty) {
            _log.w('audio file missing for ${row.id}');
            await _db.updateSyncStatus(
              row.id,
              SyncStatus.failed,
              attempts: row.syncAttempts + 1,
              lastError: 'audio file missing',
            );
            continue;
          }

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
          await _db.updateSyncStatus(row.id, SyncStatus.syncing);
          await _db.updateSyncStatus(row.id, SyncStatus.synced);
          _log.i('uploaded ${row.id}');
        } catch (e, st) {
          _log.e('upload failed for ${row.id}', error: e, stackTrace: st);
          await _db.updateSyncStatus(
            row.id,
            SyncStatus.failed,
            attempts: row.syncAttempts + 1,
            lastError: e.toString(),
          );
        }
      }
      _lastSync = DateTime.now();
    } catch (e, st) {
      _log.e('sync error', error: e, stackTrace: st);
      _lastError = e.toString();
    } finally {
      _syncing = false;
    }
  }
}

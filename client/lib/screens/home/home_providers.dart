// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/storage/storage_providers.dart';
import '../../services/connectivity_service.dart';
import '../../services/note_persistence.dart';
import '../../services/recording_playback.dart';
import '../../services/server_transcription_service.dart';
import '../../services/sync_engine.dart';
import '../server/server_connection_screen.dart'
    show transcriptionClientProvider;
import '../settings/settings_screen.dart' show settingsStoreProvider;
import 'home_screen.dart' show localDbProvider;

/// Compatibility façade; storage ownership providers are authoritative.
final audioStorageProvider = storageAudioStorageProvider;

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});

/// Server-backed transcription service. There is no on-device Whisper;
/// every "Transcribe" tap uploads audio to the user's personal Docker
/// container and listens for the SSE transcript event.
final serverTranscriptionServiceProvider =
    ChangeNotifierProvider<ServerTranscriptionService>((ref) {
  final service = ServerTranscriptionService(
    client: ref.watch(transcriptionClientProvider),
    db: ref.watch(localDbProvider),
    recordingAccess: ref.watch(recordingAccessProvider),
    mutations: ref.watch(recordingMutationsProvider),
  );
  unawaited(service.reconcilePending());
  return service;
});

// One subscription per app database, independent of the replaceable client and
// service. A detail route never owns the recovery of its committed edits.
final transcriptionRecoveryOwnerProvider = Provider<void>((ref) {
  final signals = _DurableRecoverySignals(
    ref.watch(localDbProvider),
    () => ref.read(serverTranscriptionServiceProvider),
  );
  // Retain the live coordinator without rebuilding the database subscription.
  // Notifier progress changes are not coordinator replacements.
  ref.listen(
    serverTranscriptionServiceProvider,
    (previous, next) {
      if (!identical(previous, next)) signals.coordinatorChanged();
    },
    fireImmediately: true,
  );
  ref.onDispose(signals.dispose);
});

class _DurableRecoverySignals {
  _DurableRecoverySignals(LocalDb db, this._resolveService) {
    _subscription = db.watchDumpsNeedingTranscriptionRecovery().listen(
      _changed,
      onError: (Object error, StackTrace stack) {
        // Keep known work on bounded retries while Drift awaits another update.
        _signal(_pending.keys);
      },
    );
  }

  late final StreamSubscription<List<DumpRow>> _subscription;
  final ServerTranscriptionService Function() _resolveService;
  final Set<String> _wakeups = {};
  bool _deliveryScheduled = false;
  bool _disposed = false;
  Map<String, (int, String?, String)> _pending = {};

  void coordinatorChanged() => _signal(_pending.keys, force: true);

  void _signal(Iterable<String> ids, {bool force = false}) {
    if (_disposed) return;
    _wakeups.addAll(ids);
    if (_deliveryScheduled || (_wakeups.isEmpty && !force)) return;
    _deliveryScheduled = true;
    scheduleMicrotask(() {
      _deliveryScheduled = false;
      if (_disposed) return;
      final pending = _wakeups.where(_pending.containsKey).toList();
      _wakeups.clear();
      // Never retain a service instance across asynchronous work. A read also
      // instantiates a lazy replacement when no route happens to consume it.
      _resolveService().durableRecoveryChanged(pending);
    });
  }

  void _changed(List<DumpRow> rows) {
    final next = <String, (int, String?, String)>{};
    for (final row in rows) {
      final error = row.transcriptionError ?? '';
      final work = error.startsWith('sidecar_sync_pending: manual_edit:')
          ? error // Exact UUID revision, including distinct same-text edits.
          : error.startsWith('sidecar_sync_pending:')
              ? 'sidecar'
              : 'network';
      next[row.id] =
          (row.transcriptionAttempt, row.transcriptionRequestId, work);
    }
    final changed = next.keys.where((id) => next[id] != _pending[id]).toList();
    _pending = next;
    // Progress/status/error writes for the same work never restart its timer.
    _signal(changed);
  }

  void dispose() {
    _disposed = true;
    _wakeups.clear();
    unawaited(_subscription.cancel());
  }
}

final recordingPlaybackEngineFactoryProvider =
    Provider<RecordingPlaybackEngine Function()>((ref) {
  return JustAudioRecordingPlaybackEngine.new;
});

/// Note persistence bound to the app-owned storage pipeline, mirroring the
/// wiring shape of `recordingControllerProvider`'s coordinator dependencies.
final notePersistenceProvider = Provider<NotePersistence>((ref) {
  return NotePersistence(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationsProvider),
    catalog: ref.watch(storageCatalogProvider),
  );
});

/// Sync engine instance.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    db: ref.watch(localDbProvider),
    recordingAccess: ref.watch(recordingAccessProvider),
    mutations: ref.watch(recordingMutationsProvider),
    client: ref.watch(transcriptionClientProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    settings: ref.watch(settingsStoreProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

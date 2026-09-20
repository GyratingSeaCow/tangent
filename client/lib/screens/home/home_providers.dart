// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/local_db.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart';
import '../../services/audio_file_picker.dart';
import '../../services/audio_import.dart';
import '../../services/android_transcription_notification_port.dart';
import '../../services/auto_sync_coordinator.dart';
import '../../services/connectivity_service.dart';
import '../../services/document_sync_engine.dart';
import '../../services/note_persistence.dart';
import '../../services/recording_playback.dart';
import '../../services/server_transcription_service.dart';
import '../../services/sync_engine.dart';
import '../../services/transcription_notifications.dart';
import '../server/server_connection_screen.dart'
    show transcriptionClientProvider;
import '../settings/settings_screen.dart' show settingsStoreProvider;
import 'home_screen.dart' show localDbProvider;

/// Compatibility façade; storage ownership providers are authoritative.
final audioStorageProvider = storageAudioStorageProvider;

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});

/// Opens the system picker for an audio file to import.
final audioFilePickerProvider = Provider<AudioFilePicker>((ref) {
  return AudioFilePicker();
});

/// Runs an import. Narrow on purpose: the UI only needs "import this path",
/// so tests can substitute it without standing up the whole catalog.
abstract class AudioImportRunner {
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  });
}

class _CatalogImportRunner implements AudioImportRunner {
  _CatalogImportRunner(this._ref);

  final Ref _ref;

  @override
  Future<Outcome<String>> run({
    required String sourcePath,
    required String mode,
    String? title,
  }) {
    final importer = AudioImporter(
      catalog: _ref.read(storageCatalogProvider),
      backend: _ref.read(storageBackendProvider),
      db: _ref.read(localDbProvider),
      mutations: _ref.read(recordingMutationsProvider),
      durationOf: probeAudioDuration,
    );
    return importer.import(
      sourcePath: sourcePath,
      mode: mode,
      title: title,
    );
  }
}

/// Imports an audio file into the catalog.
final audioImportRunnerProvider = Provider<AudioImportRunner>((ref) {
  return _CatalogImportRunner(ref);
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

/// The platform sink for the "Transcribing" notice. Overridden in tests with
/// a double, so no test ever reaches the real notification plugin.
final transcriptionNotificationPortProvider =
    Provider<TranscriptionNotificationPort>((ref) {
  return AndroidTranscriptionNotificationPort();
});

/// Two-way document sync (notebooks and notes) against the user's server.
///
/// Distinct from the audio SyncEngine: that one is opt-in one-way backup
/// gated on Wi-Fi, this one moves kilobytes of JSON and runs anywhere.
final documentSyncEngineProvider = Provider<DocumentSyncEngine>((ref) {
  final engine = DocumentSyncEngine(
    // Lazy: building the engine must not open a database. A sync button is
    // built on screens whose tests provide no database at all.
    db: () => ref.read(localDbProvider),
    // Read, not watched: re-pairing swaps the client, and a captured one
    // would keep talking to the old server.
    client: () => ref.read(transcriptionClientProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    deviceLabel: _deviceLabel,
    newDeviceId: const Uuid().v4(),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Owns the auto-sync watcher: local edits (write, rename, file, delete)
/// push to the server a few seconds after the user pauses, so the sync
/// button becomes a manual override rather than a chore. Read once at
/// startup, like the other owner providers — never watched.
final autoSyncOwnerProvider = Provider<void>((ref) {
  final AutoSyncCoordinator coordinator = AutoSyncCoordinator(
    db: ref.watch(localDbProvider),
    syncNow: () async {
      await ref.read(documentSyncEngineProvider).syncNow();
    },
  )..start();
  ref.onDispose(coordinator.dispose);
});

/// A human-readable name for this replica, shown in the server's device list.
///
/// Reads the real Android model (e.g. "SM-X520") so the server's device list
/// names physical hardware rather than a UUID nobody can match to a device.
/// Platform.environment does NOT carry this on Android — that mistake shipped
/// once and every device registered as the literal string "Android device".
Future<String> _deviceLabel() async {
  if (!Platform.isAndroid) return 'Tangent client';
  try {
    final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
    final String model = info.model.trim();
    return model.isNotEmpty ? model : 'Android device';
  } catch (_) {
    // A naming failure must never block sync itself.
    return 'Android device';
  }
}

/// Mirrors transcription progress into the notification shade.
///
/// Transcription runs off-screen — the user starts it and leaves — so without
/// this the only evidence it is working lives on a screen they are no longer
/// looking at. This listener is the SEAM: the notifier and its port are both
/// individually correct and do nothing at all unless something subscribes to
/// the service and drives them, which is exactly the failure mode this
/// project keeps hitting.
///
/// Watched by the home screen so it lives for the whole session rather than
/// for one route.
final transcriptionNotificationOwnerProvider = Provider<void>((ref) {
  final notifier = TranscriptionNotifier(
    port: ref.watch(transcriptionNotificationPortProvider),
  );

  void sync() {
    final service = ref.read(serverTranscriptionServiceProvider);
    unawaited(
      notifier.sync(
        hasActive: service.isTranscribing,
        queuedCount: service.queuedDumpIds.length,
      ),
    );
  }

  // A notification outlives the process that posted it: a kill during
  // transcription leaves "Transcribing" in the shade with no job behind it.
  // Cleared before the first sync so the shade starts from a state this
  // process can vouch for.
  unawaited(notifier.reconcileStaleNotification());

  // fireImmediately so a job already running at subscription time (a recovery
  // resumed at launch) is announced rather than waiting for its next event.
  ref.listen(
    serverTranscriptionServiceProvider,
    (_, __) => sync(),
    fireImmediately: true,
  );
  ref.onDispose(() => unawaited(notifier.dispose()));
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

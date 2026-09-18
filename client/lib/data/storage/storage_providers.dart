// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;
import '../../screens/recording/recording_controller.dart'
    show recordingServiceProvider;
import '../../screens/settings/settings_screen.dart' show settingsStoreProvider;
import '../../services/recording_coordinator.dart';
import '../audio_storage.dart';
import 'filesystem_storage_backend.dart';
import 'saf_storage_backend.dart';
import 'recording_mutation_coordinator.dart';
import 'recording_importer.dart';
import 'storage_catalog.dart';
import 'storage_contract.dart';
import 'storage_codec.dart';
import 'recording_access.dart';
import 'local_deletion_service.dart';
import '../../services/notebook_persistence.dart';

final storageBackendProvider = Provider<StorageBackend>(
  (ref) =>
      Platform.isAndroid ? SafStorageBackend() : FilesystemStorageBackend(),
);
final storageAudioStorageProvider = Provider<AudioStorage>((ref) {
  throw UnimplementedError('Override in main()');
});
final recordingMutationsProvider = Provider<RecordingMutationCoordinator>(
  (ref) => DefaultRecordingMutationCoordinator(db: ref.watch(localDbProvider)),
);
// Transitional name aliases the exact same app-owned provider, not a registry.
final recordingMutationCoordinatorProvider = recordingMutationsProvider;
final recordingAccessProvider = Provider<RecordingAccess>(
  (ref) => BoundRecordingAccess(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationsProvider),
  ),
);
final localDeletionServiceProvider = Provider<LocalDeletionService>(
  (ref) => DefaultLocalDeletionService(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationsProvider),
  ),
);
final defaultFolderProvider = StreamProvider<DefaultFolderState>(
  (ref) => ref.watch(storageCatalogProvider).watchDefault(),
);
final storageCatalogProvider = Provider<StorageCatalog>(
  (ref) => SqliteStorageCatalog(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationCoordinatorProvider),
    stagingDirectory: ref.watch(storageAudioStorageProvider).stagingDir.path,
    idFactory: () => const Uuid().v4(),
    now: DateTime.now,
    canChooseDefault: Platform.isAndroid,
  ),
);
final recordingImporterProvider = Provider<RecordingImporter>(
  (ref) => BoundRecordingImporter(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationCoordinatorProvider),
  ),
);
/// Everything a capture genuinely needs before it may start, and nothing else.
///
/// Recording is this app's primary function, so `start()` waits on THIS and not
/// on the folder scan: fence restoration (concurrent-capture protection),
/// legacy binding bootstrap (installs the default recording location on a
/// first-ever launch — `reserveCapture` cannot present a folder without it),
/// and owned-capture recovery (re-adopts a capture interrupted mid-write, so an
/// unfinished recording is neither lost nor duplicated).
///
/// Adopting pre-existing files and re-reading notebooks are catalog concerns;
/// they live in [catalogSyncProvider] and must never gate the record button.
final captureReadyProvider = FutureProvider<void>((ref) async {
  final backend = ref.watch(storageBackendProvider);
  final mutations = ref.watch(recordingMutationsProvider);
  await mutations.restoreFences(unsettled: await backend.unsettledUses());
  final audio = ref.watch(storageAudioStorageProvider);
  final result = await ref
      .watch(storageCatalogProvider)
      .bootstrapLegacyBindings(
        filesystemLegacyDirectory: Platform.isAndroid ? '' : audio.audioDirPath,
      );
  if (result case Fail(:final problem)) throw StorageFault(problem);
  final recovery =
      await ref.read(recordingImporterProvider).recoverOwnedCaptures();
  if (recovery case Fail(:final problem)) throw StorageFault(problem);
});

/// The folder-scanning half of startup: adopt pre-existing recordings once, and
/// re-adopt durable notebook files. Runs after capture is ready and never
/// blocks it.
final catalogSyncProvider = FutureProvider<void>((ref) async {
  await ref.watch(captureReadyProvider.future);
  final db = ref.watch(localDbProvider);
  final legacyRows = await (db.select(db.storageLocations)
        ..where((location) => location.legacyRestore.equals(true)))
      .get();
  for (final row in legacyRows) {
    final source = (
      id: row.id,
      label: row.label,
      directory: StorageCodec.decodeDirectory(row.directoryJson),
    );
    final preview = await ref.read(recordingImporterProvider).preview(source);
    final entries = switch (preview) {
      Ok<ImportPreview>(:final value) => value.entries,
      Fail<ImportPreview>(:final problem) => throw StorageFault(problem),
    };
    // Legacy restore is a one-shot migration, not a steady state. An empty
    // folder is a COMPLETED sweep — there was nothing to adopt — so it spends
    // the authorization too. Leaving the flag set re-enumerated the user's
    // folder on every single launch forever (39 recordings out of a 65-file
    // SAF directory, re-previewed at each cold start).
    var settled = true;
    if (entries.isNotEmpty) {
      final adopted = await ref.read(recordingImporterProvider).adoptConfirmed(
        (
          operationId: const Uuid().v4(),
          entries: entries,
        ),
      );
      if (adopted case Fail(:final problem)) throw StorageFault(problem);
      // Only a sweep that left nothing unsettled may spend the flag. An entry
      // that did not adopt keeps this location authorized so the next launch
      // retries it; a partial success must never silently strand files.
      settled = (adopted as Ok<ImportResult>).value.items.every(
            (item) =>
                item.state == ImportState.adopted ||
                item.state == ImportState.alreadyKnown,
          );
    }
    if (settled) await db.completeLegacyRestore(row.id);
  }
  // Re-adopt durable notebook files. Recordings alone are not the whole
  // folder: a reinstall that restored dumps but skipped this left every
  // <id>.notebook.json stranded on disk with no way back into the app.
  try {
    await ref.read(notebookPersistenceProvider).importNotebooks();
  } catch (_) {
    // Notebook adoption is best-effort: recordings and capture recovery must
    // not be held hostage by an unreadable notebook file.
  }
});

/// Full startup: capture readiness followed by the catalog sweep. Callers that
/// need the whole folder reconciled (startup orchestration, tests) await this;
/// the record button deliberately does not.
final storageBootstrapProvider = FutureProvider<void>((ref) async {
  await ref.watch(captureReadyProvider.future);
  await ref.watch(catalogSyncProvider.future);
});
final recordingCoordinatorProvider = Provider<RecordingCoordinator>(
  (ref) => DefaultRecordingCoordinator(
    db: ref.watch(localDbProvider),
    catalog: ref.watch(storageCatalogProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationCoordinatorProvider),
    recorder: ref.watch(recordingServiceProvider),
    now: DateTime.now,
    // Same store the recorder reads, so the staging extension and the capture
    // path always agree about whether this recording is amplified.
    micGain: () => ref.read(settingsStoreProvider).micGain,
  ),
);

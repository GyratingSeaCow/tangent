// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;
import '../../screens/recording/recording_controller.dart'
    show recordingServiceProvider;
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
final storageBootstrapProvider = FutureProvider<void>((ref) async {
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
    if (entries.isEmpty) continue;
    final adopted = await ref.read(recordingImporterProvider).adoptConfirmed(
      (
        operationId: const Uuid().v4(),
        entries: entries,
      ),
    );
    if (adopted case Fail(:final problem)) throw StorageFault(problem);
  }
  final recovery =
      await ref.read(recordingImporterProvider).recoverOwnedCaptures();
  if (recovery case Fail(:final problem)) throw StorageFault(problem);
});
final recordingCoordinatorProvider = Provider<RecordingCoordinator>(
  (ref) => DefaultRecordingCoordinator(
    db: ref.watch(localDbProvider),
    catalog: ref.watch(storageCatalogProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationCoordinatorProvider),
    recorder: ref.watch(recordingServiceProvider),
    now: DateTime.now,
  ),
);

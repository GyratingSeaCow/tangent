// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../screens/home/home_providers.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;
import '../../screens/recording/recording_controller.dart'
    show recordingServiceProvider;
import '../../services/recording_coordinator.dart';
import 'filesystem_storage_backend.dart';
import 'saf_storage_backend.dart';
import 'recording_mutation_coordinator.dart';
import 'recording_importer.dart';
import 'storage_catalog.dart';
import 'storage_contract.dart';

final storageBackendProvider = Provider<StorageBackend>(
  (ref) =>
      Platform.isAndroid ? SafStorageBackend() : FilesystemStorageBackend(),
);
final recordingMutationCoordinatorProvider =
    Provider<RecordingMutationCoordinator>(
  (ref) => DefaultRecordingMutationCoordinator(db: ref.watch(localDbProvider)),
);
final storageCatalogProvider = Provider<StorageCatalog>(
  (ref) => SqliteStorageCatalog(
    db: ref.watch(localDbProvider),
    backend: ref.watch(storageBackendProvider),
    mutations: ref.watch(recordingMutationCoordinatorProvider),
    stagingDirectory: ref.watch(audioStorageProvider).stagingDir.path,
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
  final audio = ref.watch(audioStorageProvider);
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

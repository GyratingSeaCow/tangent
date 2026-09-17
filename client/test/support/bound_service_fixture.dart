// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/recording_access.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/storage_contract.dart';

final class BoundServiceFixture {
  BoundServiceFixture({required this.access, required this.mutations});

  final BoundRecordingAccess access;
  final DefaultRecordingMutationCoordinator mutations;
}

Future<BoundServiceFixture> createBoundServiceFixture(
  LocalDb db, {
  StorageBackend? backend,
  bool registerDrain = true,
}) async {
  final mutations = DefaultRecordingMutationCoordinator(db: db);
  await mutations.restoreFences();
  if (registerDrain) addTearDown(mutations.drain);
  return BoundServiceFixture(
    access: BoundRecordingAccess(
      db: db,
      backend: backend ?? FilesystemStorageBackend(),
      mutations: mutations,
    ),
    mutations: mutations,
  );
}

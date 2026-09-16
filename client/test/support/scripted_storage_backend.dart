// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'storage_fixture.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';

final class CatalogHarness {
  CatalogHarness() {
    resetOwners();
  }
  final f = StorageFixture.create();
  final backend = ScriptedStorageBackend();
  late DefaultRecordingMutationCoordinator mutations;
  late SqliteStorageCatalog catalog;
  int counter = 0;
  void resetOwners({bool canChooseDefault = true}) {
    mutations = DefaultRecordingMutationCoordinator(db: f.db);
    catalog = SqliteStorageCatalog(
      db: f.db,
      backend: backend,
      mutations: mutations,
      stagingDirectory: f.directory('stage'),
      idFactory: () => 'fixture-key-${counter++}',
      now: () => DateTime.utc(2030),
      canChooseDefault: canChooseDefault,
    );
  }

  Future<void> bootstrap() async {
    requireOk(
      await catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: f.directory('A'),
      ),
    );
  }

  Future<void> reopen() async {
    await backend.drain();
    await mutations.drain();
    await f.reopen();
    resetOwners();
  }

  Future<FolderCandidate> choose(String folder) async {
    backend.choice = Ok(fileLocation(folder, f.directory(folder)));
    return requireOk<FolderCandidate?>(await catalog.chooseFolderCandidate())!;
  }

  Future<void> close() async {
    await backend.drain();
    await mutations.drain();
    await f.close();
  }
}

final class ImmediateIo<T> implements IoOperation<T> {
  ImmediateIo(this.id, T value) : result = Future.value(value);
  @override
  final String id;
  @override
  final Future<T> result;
  @override
  Future<void> get settled => Future.value();
}

final class GatedIo<T> implements IoOperation<T> {
  GatedIo(this.id, this.result, this.settled);
  @override
  final String id;
  @override
  final Future<T> result;
  @override
  final Future<void> settled;
}

class ScriptedStorageBackend extends FilesystemStorageBackend {
  Outcome<StorageLocation?> choice = const Ok(null);
  bool validationFails = false;
  bool metadataDeleteFails = false;
  int componentCalls = 0;
  int captureCalls = 0;
  int inventoryCalls = 0;
  final resolutionInputs = <String>[];
  final listed = <StorageLocation>[];
  Future<Outcome<StorageLocation?>> Function()? picker;
  Future<List<RestoredUse>> Function()? inventory;
  Future<Outcome<LegacyStorage?>> Function(String path, String? anchor)? legacy;
  IoOperation<Outcome<ProbeReceipt>> Function(String, StorageLocation)? probe;
  IoOperation<Outcome<List<ImportedEntry>>> Function(StorageLocation)? listing;
  @override
  Future<List<RestoredUse>> unsettledUses() async {
    inventoryCalls++;
    return inventory == null ? super.unsettledUses() : inventory!();
  }

  @override
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({
    required String filesystemLegacyDirectory,
    String? frozenAnchorJson,
  }) {
    if (frozenAnchorJson == null) {
      captureCalls++;
    } else {
      resolutionInputs.add(frozenAnchorJson);
    }
    return legacy == null
        ? super.inspectLegacyStorage(
            filesystemLegacyDirectory: filesystemLegacyDirectory,
            frozenAnchorJson: frozenAnchorJson,
          )
        : legacy!(filesystemLegacyDirectory, frozenAnchorJson);
  }

  @override
  Future<Outcome<StorageLocation?>> pickDirectory() async =>
      picker == null ? choice : picker!();
  @override
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(
    String token,
    StorageLocation location,
  ) {
    if (probe != null) return probe!(token, location);
    if (validationFails) {
      return ImmediateIo(
        'probe-$token',
        const Fail(
          (code: ProblemCode.denied, message: 'synthetic validation denial'),
        ),
      );
    }
    return super.validateCandidate(token, location);
  }

  @override
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(
    StorageLocation location,
  ) {
    listed.add(location);
    return listing == null
        ? super.listRecordingsAt(location)
        : listing!(location);
  }

  @override
  IoOperation<ComponentResult> deleteComponent(
    BoundRecording binding,
    RecordingComponent component,
    String operationId,
  ) {
    componentCalls++;
    if (metadataDeleteFails && component == RecordingComponent.metadata) {
      return ImmediateIo(
        operationId,
        (
          state: ComponentState.failed,
          problem: (
            code: ProblemCode.denied,
            message: 'synthetic metadata denial'
          )
        ),
      );
    }
    return super.deleteComponent(binding, component, operationId);
  }
}

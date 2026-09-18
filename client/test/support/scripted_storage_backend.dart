// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'storage_fixture.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';

final class CatalogHarness {
  static int _nextFixture = 0;
  final int fixtureId = _nextFixture++;
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
      idFactory: () => 'fixture-key-$fixtureId-${counter++}',
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

/// Narrows a listing operation to the single entry [dumpId], preserving the
/// underlying operation's id and settlement so lease accounting is identical
/// to the listing path.
class _SingleEntryOperation implements IoOperation<Outcome<ImportedEntry?>> {
  _SingleEntryOperation(this._source, this._dumpId);
  final IoOperation<Outcome<List<ImportedEntry>>> _source;
  final String _dumpId;

  @override
  String get id => _source.id;

  @override
  Future<void> get settled => _source.settled;

  @override
  Future<Outcome<ImportedEntry?>> get result =>
      _source.result.then((outcome) => switch (outcome) {
            Ok(value: final entries) => Ok<ImportedEntry?>(
                entries.where((e) => e.id == _dumpId).firstOrNull,
              ),
            Fail(problem: final problem) => Fail<ImportedEntry?>(problem),
          },);
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
  final publishedReservations = <CaptureReservation>[];
  IoOperation<Outcome<PublishedCapture>> Function(
    CaptureReservation,
    PreparedCapture,
  )? publication;
  IoOperation<Outcome<DurableDocument>> Function(
    StorageLocation,
    String,
    String,
    String,
    String,
  )? documentPublication;
  final publishedDocuments = <String>[];
  @override
  IoOperation<Outcome<DurableDocument>> publishDocument(
    StorageLocation location,
    String directoryName,
    String name,
    String content,
    String publicationId,
  ) {
    publishedDocuments.add(name);
    return documentPublication == null
        ? super.publishDocument(
            location,
            directoryName,
            name,
            content,
            publicationId,
          )
        : documentPublication!(
            location,
            directoryName,
            name,
            content,
            publicationId,
          );
  }

  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) {
    publishedReservations.add(r);
    return publication == null
        ? super.publishPreparedCapture(r, preparation)
        : publication!(r, preparation);
  }

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

  /// Opt-in single-entry read, mirroring what the SAF backend does natively.
  ///
  /// Off by default so every existing test keeps exercising the listing path
  /// unchanged. When enabled, it serves the entry from the same listing the
  /// real backend would return, so the fast path cannot "pass" by inventing
  /// an entry the folder does not actually contain.
  bool singleEntryReads = false;
  int singleReadCalls = 0;

  @override
  IoOperation<Outcome<ImportedEntry?>>? readRecordingAt(
    StorageLocation location,
    String dumpId,
  ) {
    if (!singleEntryReads) {
      return null;
    }
    singleReadCalls++;
    final source = listing == null
        ? super.listRecordingsAt(location)
        : listing!(location);
    return _SingleEntryOperation(source, dumpId);
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

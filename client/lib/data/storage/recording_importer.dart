// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:drift/native.dart' show SqliteException;
import 'package:uuid/uuid.dart';
import '../local_db.dart';
import '../recording_metadata.dart';
import '../../services/recording_persistence.dart';
import 'storage_codec.dart';
import 'storage_contract.dart';

class BoundRecordingImporter implements RecordingImporter {
  BoundRecordingImporter({
    required LocalDb db,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
  })  : _db = db,
        _backend = backend,
        _mutations = mutations;
  final LocalDb _db;
  final StorageBackend _backend;
  final RecordingMutationCoordinator _mutations;
  Future<void>? _initializing;
  Future<void> _ready() => _initializing ??= () async {
        try {
          await _mutations.restoreFences(
            unsettled: await _backend.unsettledUses(),
          );
        } catch (_) {
          _initializing = null;
          rethrow;
        }
      }();
  Never _fault(ProblemCode code, String message) =>
      throw StorageFault((code: code, message: message));
  T _value<T>(Outcome<T> result) => switch (result) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem)
      };
  Future<T> _settled<T>(IoOperation<T> operation) async {
    try {
      return await operation.result;
    } finally {
      await operation.settled;
    }
  }

  Future<Outcome<T>> _guard<T>(Future<T> Function() action) async {
    try {
      await _ready();
      return Ok(await action());
    } on StorageFault catch (e) {
      return Fail(e.problem);
    } on SqliteException {
      return const Fail(
        (code: ProblemCode.persistence, message: 'Import persistence failed'),
      );
    } on FileSystemException {
      return const Fail(
        (code: ProblemCode.io, message: 'Import storage unavailable'),
      );
    }
  }

  ImportedEntry _validated(
    ImportedEntry entry, {
    StorageLocation? expectedSource,
  }) {
    if (entry.problem != null) return entry;
    StorageProblem? problem;
    try {
      StorageCodec.validateLiteralId(entry.id);
      StorageCodec.encodeLocation(entry.source);
      StorageCodec.encodeAudio(entry.audio);
      if (expectedSource != null &&
          StorageCodec.canonicalKey(entry.source.directory) !=
              StorageCodec.canonicalKey(expectedSource.directory)) {
        _fault(ProblemCode.invalid, 'Enumeration source mismatch');
      }
      if (entry.audio.kind != entry.source.directory.kind ||
          entry.sizeBytes <= 0) {
        _fault(ProblemCode.invalid, 'Invalid imported audio');
      }
      validateImportedMetadata(entry.id, entry.metadata);
    } on StorageFault catch (e) {
      problem = e.problem;
    }
    return (
      id: entry.id,
      source: entry.source,
      audio: entry.audio,
      sizeBytes: entry.sizeBytes,
      modifiedAt: entry.modifiedAt,
      metadata: entry.metadata,
      problem: problem
    );
  }

  @override
  Future<Outcome<ImportPreview>> preview(StorageLocation source) =>
      _guard(() async {
        StorageCodec.encodeLocation(source);
        final entries =
            _value(await _settled(_backend.listRecordingsAt(source)));
        return (
          entries:
              entries.map((e) => _validated(e, expectedSource: source)).toList()
        );
      });
  ImportItemResult _result(
    String id,
    ImportState state, [
    StorageProblem? problem,
  ]) =>
      (id: id, state: state, problem: problem);
  @override
  Future<Outcome<ImportResult>> adoptConfirmed(ConfirmedImport selection) =>
      _guard(() async {
        StorageCodec.validateLiteralId(selection.operationId);
        final results = <ImportItemResult>[];
        // Re-read each source ONCE per adoption, not once per entry. The
        // freshness check below still compares every confirmed entry against
        // what the folder holds now; it just stops paying for a full
        // enumeration per file. Adopting 39 recordings used to trigger 39
        // enumerations of a 65-file SAF directory (~2.5 min of native I/O on
        // device) and re-ran every launch, starving the rest of bootstrap.
        final freshBySource = <String, List<ImportedEntry>>{};
        Future<List<ImportedEntry>> currentFor(StorageLocation source) async {
          final key = StorageCodec.canonicalKey(source.directory);
          return freshBySource[key] ??= _value(await preview(source)).entries;
        }

        for (final selected in selection.entries) {
          try {
            final validated = _validated(selected);
            if (validated.problem != null) {
              throw StorageFault(validated.problem!);
            }
            final current = (await currentFor(selected.source))
                .where((e) => e.id == selected.id)
                .toList();
            if (current.length != 1) {
              _fault(
                current.isEmpty ? ProblemCode.unavailable : ProblemCode.invalid,
                'Original import entry not uniquely available',
              );
            }
            final entry = current.single;
            if (entry.problem != null) throw StorageFault(entry.problem!);
            if (!StorageCodec.sameAudioIdentity(entry.audio, selected.audio) ||
                entry.sizeBytes != selected.sizeBytes ||
                entry.modifiedAt != selected.modifiedAt) {
              _fault(
                ProblemCode.conflict,
                'Import source changed after confirmation',
              );
            }
            results.add(await _mutations.catalogAdmission(() => _adopt(entry)));
          } on StorageFault catch (e) {
            results.add(
              _result(
                selected.id,
                switch (e.problem.code) {
                  ProblemCode.retired => ImportState.retired,
                  ProblemCode.invalid => ImportState.invalid,
                  ProblemCode.conflict ||
                  ProblemCode.fenced ||
                  ProblemCode.busy ||
                  ProblemCode.wrongIncarnation =>
                    ImportState.collision,
                  _ => ImportState.unavailable,
                },
                e.problem,
              ),
            );
          } on SqliteException {
            results.add(
              _result(
                selected.id,
                ImportState.unavailable,
                (
                  code: ProblemCode.persistence,
                  message: 'Import persistence failed'
                ),
              ),
            );
          } on FileSystemException {
            results.add(
              _result(
                selected.id,
                ImportState.unavailable,
                (code: ProblemCode.io, message: 'Import source unavailable'),
              ),
            );
          }
        }
        return (items: results);
      });
  @override
  Future<Outcome<OwnedCaptureRecoveryResult>> recoverOwnedCaptures() => _guard(
        () => RecordingPersistence(
          db: _db,
          backend: _backend,
          mutations: _mutations,
        ).recoverOwnedCaptures(),
      );
  Future<ImportItemResult> _adopt(ImportedEntry entry) async {
    UseLease? lease;
    try {
      return await _db.transaction(() async {
        final id = entry.id;
        final ticket = await (_db.select(_db.localDeletionTickets)
              ..where((t) => t.dumpId.equals(id)))
            .getSingleOrNull();
        if (ticket != null) {
          _fault(
            ticket.state == 'completed'
                ? ProblemCode.retired
                : ProblemCode.fenced,
            'Import identity fenced',
          );
        }
        final reservation = await (_db.select(_db.captureReservations)
              ..where((r) => r.dumpId.equals(id)))
            .getSingleOrNull();
        if (reservation != null) {
          _fault(ProblemCode.conflict, 'Identity belongs to an owned capture');
        }
        final existing = await _db.getDump(id);
        final binding = await _db.boundRecording(id);
        if (existing != null) {
          if (binding == null ||
              StorageCodec.canonicalKey(binding.location.directory) !=
                  StorageCodec.canonicalKey(entry.source.directory) ||
              !StorageCodec.sameAudioIdentity(binding.audio, entry.audio)) {
            _fault(
              ProblemCode.conflict,
              'Same ID has a different original source',
            );
          }
          return _result(id, ImportState.alreadyKnown);
        }
        final anyBinding = await (_db.select(_db.recordingBindings)
              ..where((b) => b.dumpId.equals(id)))
            .getSingleOrNull();
        if (anyBinding != null) {
          _fault(ProblemCode.conflict, 'Binding already claims identity');
        }
        final canonical = StorageCodec.canonicalKey(entry.source.directory);
        var location = await (_db.select(_db.storageLocations)
              ..where((l) => l.canonicalKey.equals(canonical)))
            .getSingleOrNull();
        if (entry.metadata == null && location?.legacyRestore != true) {
          _fault(
            ProblemCode.invalid,
            'Audio-only discovery requires an authorized legacy source',
          );
        }
        final key = (dumpId: id, incarnation: const Uuid().v4());
        lease = _value(
          await _mutations.acquire(
            id,
            UseKind.capture,
            expectedIncarnation: key.incarnation,
          ),
        );
        if (location == null) {
          final locationId = const Uuid().v4();
          await _db.into(_db.storageLocations).insert(
                StorageLocationsCompanion.insert(
                  id: locationId,
                  canonicalKey: canonical,
                  directoryJson:
                      StorageCodec.encodeDirectory(entry.source.directory),
                  label: entry.source.label,
                ),
              );
          location = await (_db.select(_db.storageLocations)
                ..where((l) => l.id.equals(locationId)))
              .getSingle();
        }
        final registered = (
          id: location.id,
          directory: StorageCodec.decodeDirectory(location.directoryJson),
          label: location.label
        );
        final row = importedDumpRow(
          id: id,
          locator: entry.audio.value,
          sizeBytes: entry.sizeBytes,
          modifiedAt: entry.modifiedAt,
          metadata: entry.metadata,
        );
        await _db.into(_db.dumps).insert(row);
        await _db.bindRecording(
          (
            key: key,
            location: registered,
            audio: entry.audio,
            metadataName: '$id.meta.json'
          ),
        );
        return _result(id, ImportState.adopted);
      });
    } finally {
      await lease?.close();
    }
  }
}

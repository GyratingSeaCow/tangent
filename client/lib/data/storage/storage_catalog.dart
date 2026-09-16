// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift/native.dart' show SqliteException;
import '../local_db.dart';
import 'storage_codec.dart';
import 'storage_contract.dart';

/// SQLite is the authority. Provider work is always outside transactions.
class SqliteStorageCatalog implements StorageCatalog {
  SqliteStorageCatalog({
    required LocalDb db,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
    required String stagingDirectory,
    required String Function() idFactory,
    required DateTime Function() now,
    required bool canChooseDefault,
  })  : _db = db,
        _backend = backend,
        _mutations = mutations,
        _stagingDirectory = stagingDirectory,
        _idFactory = idFactory,
        _now = now,
        _canChooseDefault = canChooseDefault;
  final String _stagingDirectory;
  final String Function() _idFactory;
  final DateTime Function() _now;
  final bool _canChooseDefault;
  final LocalDb _db;
  final StorageBackend _backend;
  final RecordingMutationCoordinator _mutations;
  Future<void>? _initializing;
  Never _fault(ProblemCode code, String message) =>
      throw StorageFault((code: code, message: message));
  T _value<T>(Outcome<T> result) => switch (result) {
        Ok<T>(:final value) => value,
        Fail<T>(:final problem) => throw StorageFault(problem)
      };
  Future<Outcome<T>> _guard<T>(Future<T> Function() action) async {
    try {
      return Ok(await action());
    } on StorageFault catch (e) {
      return Fail(e.problem);
    } on SqliteException {
      return const Fail(
        (
          code: ProblemCode.persistence,
          message: 'Storage catalog persistence failed'
        ),
      );
    }
  }

  Future<void> _ready() => _initializing ??= () async {
        try {
          final inventory = await _backend.unsettledUses();
          await _mutations.restoreFences(unsettled: inventory);
          await _mutations.catalogAdmission(
            () => _db.transaction(() async {
              final state = await _state();
              final candidate = _candidate(state.candidateJson);
              if (candidate != null &&
                  candidate['processEpoch'] != _mutations.processEpoch &&
                  candidate['phase'] != 'consumed') {
                await _saveCandidate({...candidate, 'phase': 'interrupted'});
              }
              await (_db.update(_db.captureReservations)
                    ..where(
                      (r) =>
                          r.processEpoch.equals(_mutations.processEpoch).not() &
                          r.state.isIn([
                            'reserved',
                            'recording',
                            'stopped',
                            'publishing',
                          ]),
                    ))
                  .write(
                const CaptureReservationsCompanion(
                  state: Value('interrupted'),
                ),
              );
            }),
          );
        } catch (_) {
          _initializing = null;
          rethrow;
        }
      }();
  Future<StorageCatalogStateRow> _state() =>
      (_db.select(_db.storageCatalogStates)..where((s) => s.id.equals(1)))
          .getSingle();
  String _anchorKind(String anchor) {
    Object? decoded;
    try {
      decoded = jsonDecode(anchor);
    } on FormatException {
      _fault(ProblemCode.invalid, 'Malformed legacy envelope');
    }
    final kind = decoded is Map ? decoded['kind'] : null;
    if (kind is! String) {
      _fault(ProblemCode.invalid, 'Missing legacy envelope kind');
    }
    StorageCodec.decodeLegacyAnchor(anchor, expectedKind: kind);
    return kind;
  }

  Future<T> _settled<T>(IoOperation<T> operation) async {
    try {
      return await operation.result;
    } finally {
      await operation.settled;
    }
  }

  Future<StorageLocation> _register(
    StorageLocation location, {
    bool legacy = false,
  }) async {
    final canonical = StorageCodec.canonicalKey(location.directory);
    final existing = await (_db.select(_db.storageLocations)
          ..where((l) => l.canonicalKey.equals(canonical)))
        .getSingleOrNull();
    if (existing != null) {
      if (legacy && !existing.legacyRestore) {
        await (_db.update(_db.storageLocations)
              ..where((l) => l.id.equals(existing.id)))
            .write(const StorageLocationsCompanion(legacyRestore: Value(true)));
      }
      return (
        id: existing.id,
        directory: StorageCodec.decodeDirectory(existing.directoryJson),
        label: existing.label
      );
    }
    StorageCodec.encodeLocation(location);
    await _db.into(_db.storageLocations).insert(
          StorageLocationsCompanion.insert(
            id: location.id,
            canonicalKey: canonical,
            directoryJson: StorageCodec.encodeDirectory(location.directory),
            label: location.label,
            legacyRestore: Value(legacy),
          ),
        );
    return location;
  }

  Future<StorageLocation?> _location(String? id) async {
    if (id == null) return null;
    final row = await (_db.select(_db.storageLocations)
          ..where((l) => l.id.equals(id)))
        .getSingleOrNull();
    return row == null
        ? null
        : (
            id: row.id,
            directory: StorageCodec.decodeDirectory(row.directoryJson),
            label: row.label
          );
  }

  Future<DefaultFolderState> _present(StorageCatalogStateRow state) async {
    final location = await _location(state.defaultLocationId);
    StorageProblem? problem;
    if (location == null) {
      problem = (
        code: ProblemCode.unavailable,
        message: 'No default recording folder'
      );
    } else {
      final inspection = await _settled(_backend.inspectLocation(location));
      if (inspection is Fail<void>) problem = inspection.problem;
    }
    return (
      location: location,
      revision: state.revision,
      available: problem == null,
      canChooseDefault: _canChooseDefault,
      problem: problem
    );
  }

  @override
  Stream<DefaultFolderState> watchDefault() async* {
    await _ready();
    await for (final _ in _db.customSelect(
      'SELECT id FROM storage_catalog_state',
      readsFrom: {_db.storageCatalogStates, _db.storageLocations},
    ).watch()) {
      yield await _present(await _state());
    }
  }

  Map<String, dynamic>? _candidate(String? encoded) {
    if (encoded == null) return null;
    Object? value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      _fault(ProblemCode.invalid, 'Malformed folder candidate');
    }
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['token'] is! String ||
        value['processEpoch'] is! String ||
        value['phase'] is! String) {
      _fault(ProblemCode.invalid, 'Invalid folder candidate');
    }
    return value;
  }

  Future<void> _saveCandidate(Map<String, dynamic> candidate) async {
    await (_db.update(_db.storageCatalogStates)..where((s) => s.id.equals(1)))
        .write(
      StorageCatalogStatesCompanion(
        candidateJson: Value(jsonEncode(candidate)),
      ),
    );
  }

  bool _matches(Map<String, dynamic>? stored, String token) =>
      stored != null &&
      stored['token'] == token &&
      stored['processEpoch'] == _mutations.processEpoch;
  String _newId() {
    final id = _idFactory();
    StorageCodec.validateLiteralId(id);
    return id;
  }

  @override
  Future<Outcome<FolderCandidate?>> chooseFolderCandidate() => _guard(() async {
        await _ready();
        if (!_canChooseDefault) {
          _fault(ProblemCode.unsupported, 'Folder selection is Android-only');
        }
        final token = '${_mutations.processEpoch}-${_newId()}';
        await _mutations.catalogAdmission(
          () => _db.transaction(() async {
            final previous = _candidate((await _state()).candidateJson);
            if (previous?['phase'] == 'probing') {
              _fault(ProblemCode.busy, 'A folder probe is still running');
            }
            // Preserve exact orphan/unknown-cleanup receipts; never sweep by filename.
            final retained = <dynamic>[...?previous?['retained'] as List?];
            if (previous != null &&
                previous['cleaned'] != true &&
                previous['location'] != null) {
              retained.add({...previous}..remove('retained'));
            }
            await _saveCandidate({
              'version': 1,
              'token': token,
              'processEpoch': _mutations.processEpoch,
              'phase': 'picking',
              'location': null,
              'owned': <Object?>[],
              'cleaned': false,
              'retained': retained,
            });
          }),
        );
        final picked = await _backend.pickDirectory();
        return _mutations.catalogAdmission(() async {
          var stored = _candidate((await _state()).candidateJson);
          if (!_matches(stored, token)) {
            _fault(ProblemCode.conflict, 'Folder choice was superseded');
          }
          if (picked is Fail<StorageLocation?>) {
            await _saveCandidate({...stored!, 'phase': 'failed'});
            throw StorageFault(picked.problem);
          }
          final location = (picked as Ok<StorageLocation?>).value;
          if (location == null) {
            await _saveCandidate({...stored!, 'phase': 'canceled'});
            return null;
          }
          StorageCodec.encodeLocation(location);
          await _saveCandidate({
            ...stored!,
            'phase': 'probing',
            'location': jsonDecode(StorageCodec.encodeLocation(location)),
          });
          late Outcome<ProbeReceipt> result;
          IoOperation<Outcome<ProbeReceipt>>? probe;
          try {
            probe = _backend.validateCandidate(token, location);
            result = await probe.result;
          } on StorageFault catch (e) {
            // A failed result is not actual settlement. Persist failure only
            // after the finally barrier; a rejected barrier stays fail-closed.
            result = Fail(e.problem);
          } finally {
            if (probe != null) await probe.settled;
          }
          stored = _candidate((await _state()).candidateJson);
          if (!_matches(stored, token)) {
            _fault(ProblemCode.conflict, 'Folder probe was superseded');
          }
          if (result is Fail<ProbeReceipt>) {
            await _saveCandidate({...stored!, 'phase': 'failed'});
            throw StorageFault(result.problem);
          }
          final receipt = (result as Ok<ProbeReceipt>).value;
          final owned = receipt.owned
              .map((a) => jsonDecode(StorageCodec.encodeAudio(a)))
              .toList();
          await _saveCandidate({
            ...stored!,
            'phase': receipt.cleaned ? 'validated' : 'failed',
            'owned': owned,
            'cleaned': receipt.cleaned,
          });
          if (!receipt.cleaned) {
            _fault(ProblemCode.io, 'Folder probe cleanup is unconfirmed');
          }
          return (token: token, location: location);
        });
      });
  Future<bool> _captureBusy() async =>
      _mutations.hasActiveCapture ||
      (await (_db.select(_db.captureReservations)
                ..where(
                  (r) => r.state
                      .isIn(['reserved', 'recording', 'stopped', 'publishing']),
                ))
              .get())
          .isNotEmpty;

  @override
  Future<Outcome<DefaultFolderState>> commitDefault(
    FolderCandidate candidate, {
    required int expectedRevision,
  }) =>
      _guard(() async {
        await _ready();
        if (!_canChooseDefault) {
          _fault(ProblemCode.unsupported, 'Folder selection is Android-only');
        }
        return _mutations.catalogAdmission(() async {
          StorageCatalogStateRow committed;
          try {
            committed = await _db.commitStorageCatalog(() async {
              final state = await _state();
              final stored = _candidate(state.candidateJson);
              if (!_matches(stored, candidate.token) ||
                  stored!['phase'] != 'validated' ||
                  stored['cleaned'] != true ||
                  StorageCodec.decodeLocation(jsonEncode(stored['location'])) !=
                      candidate.location) {
                _fault(
                  ProblemCode.conflict,
                  'Folder candidate is not valid for this process',
                );
              }
              if (state.revision != expectedRevision) {
                _fault(
                  ProblemCode.staleRevision,
                  'Default folder revision changed',
                );
              }
              if (await _captureBusy()) {
                _fault(ProblemCode.busy, 'Recording or finalization is active');
              }
              final location = await _register(candidate.location);
              final revision = state.revision +
                  (state.defaultLocationId == location.id ? 0 : 1);
              await (_db.update(_db.storageCatalogStates)
                    ..where((s) => s.id.equals(1)))
                  .write(
                StorageCatalogStatesCompanion(
                  defaultLocationId: Value(location.id),
                  revision: Value(revision),
                  candidateJson: Value(
                    jsonEncode({
                      ...stored,
                      'phase': 'consumed',
                      'committedRevision': revision,
                    }),
                  ),
                ),
              );
              return _state();
            });
          } on SqliteException {
            committed = await _state();
            final saved = _candidate(committed.candidateJson);
            if (!_matches(saved, candidate.token) ||
                saved!['phase'] != 'consumed' ||
                saved['committedRevision'] != committed.revision ||
                StorageCodec.canonicalKey(
                      (await _location(committed.defaultLocationId))!.directory,
                    ) !=
                    StorageCodec.canonicalKey(candidate.location.directory)) {
              _fault(
                ProblemCode.persistence,
                'Default commit was not confirmed',
              );
            }
          }
          return _present(committed);
        });
      });

  @override
  Future<Outcome<BoundRecording>> resolveRecording(String dumpId) =>
      _guard(() async {
        await _ready();
        StorageCodec.validateLiteralId(dumpId);
        return _db.transaction(() async {
          if (await _db.isRetired(dumpId)) {
            _fault(ProblemCode.retired, 'Recording ID is retired');
          }
          if (await _db.getDump(dumpId) == null) {
            _fault(ProblemCode.absent, 'Recording is missing');
          }
          final binding = await _db.boundRecording(dumpId);
          if (binding == null) {
            _fault(ProblemCode.unresolved, 'Original storage is unresolved');
          }
          return binding;
        });
      });
  @override
  Future<Outcome<CaptureReservation>> reserveCapture({required String mode}) =>
      _guard(() async {
        await _ready();
        if (!['brain_dump', 'meeting'].contains(mode)) {
          _fault(ProblemCode.invalid, 'Invalid recording mode');
        }
        return _mutations.catalogAdmission(() async {
          if (await _captureBusy()) {
            _fault(ProblemCode.busy, 'Recording or finalization is active');
          }
          final state = await _state();
          final presented = await _present(state);
          if (!presented.available) throw StorageFault(presented.problem!);
          final location = presented.location!;
          // No staging creation or microphone work at reservation time.
          StorageCodec.encodeDirectory(
            (
              kind: 'file',
              path: _stagingDirectory,
              treeUri: '',
              authority: '',
              documentId: ''
            ),
          );
          return _db.transaction(() async {
            final current = await _state();
            if (current.defaultLocationId != state.defaultLocationId ||
                current.revision != state.revision) {
              _fault(
                ProblemCode.staleRevision,
                'Default changed before reservation',
              );
            }
            if (await _captureBusy()) {
              _fault(ProblemCode.busy, 'Recording or finalization is active');
            }
            String? id;
            for (var attempt = 0; attempt < 32; attempt++) {
              final next = _newId();
              final occupied = await _db.customSelect(
                'SELECT 1 FROM dumps WHERE id=? UNION ALL SELECT 1 FROM recording_bindings WHERE dump_id=? UNION ALL SELECT 1 FROM local_deletion_tickets WHERE dump_id=? UNION ALL SELECT 1 FROM capture_reservations WHERE dump_id=? OR reservation_id=?',
                variables: [
                  for (var i = 0; i < 5; i++) Variable.withString(next),
                ],
              ).get();
              if (occupied.isEmpty) {
                id = next;
                break;
              }
            }
            if (id == null) {
              _fault(ProblemCode.conflict, 'No unused capture identity');
            }
            final incarnation = _newId();
            final reservationId = '${_mutations.processEpoch}-$id';
            final startedAt = _now();
            final stagingPath =
                '$_stagingDirectory${_stagingDirectory.endsWith('/') || _stagingDirectory.endsWith('\\') ? '' : '/'}$reservationId.opus';
            await _db.into(_db.captureReservations).insert(
                  CaptureReservationsCompanion.insert(
                    reservationId: reservationId,
                    dumpId: id,
                    incarnation: incarnation,
                    locationId: location.id,
                    stagingPath: stagingPath,
                    mode: mode,
                    startedAt: startedAt.millisecondsSinceEpoch,
                    state: 'reserved',
                    processEpoch: _mutations.processEpoch,
                  ),
                );
            return (
              id: reservationId,
              key: (dumpId: id, incarnation: incarnation),
              location: location,
              stagingPath: stagingPath,
              mode: mode,
              startedAt: startedAt,
              phase: CapturePhase.reserved
            );
          });
        });
      });

  @override
  Future<Outcome<BootstrapResult>> bootstrapLegacyBindings({
    required String filesystemLegacyDirectory,
  }) =>
      _guard(() async {
        await _ready();
        return _mutations.catalogAdmission(() async {
          var state = await _state();
          if (state.legacyAnchorJson == null) {
            if (state.bootstrapVersion != 0) {
              _fault(
                ProblemCode.invalid,
                'Completed bootstrap has no frozen source',
              );
            }
            final captured = _value(
              await _backend.inspectLegacyStorage(
                filesystemLegacyDirectory: filesystemLegacyDirectory,
              ),
            );
            if (captured?.location != null) {
              _fault(
                ProblemCode.invalid,
                'Capture returned a resolved location',
              );
            }
            final candidate = captured?.anchorJson ??
                StorageCodec.encodeLegacySafAnchor(null);
            _anchorKind(candidate);
            try {
              await _db.freezeLegacyAnchor(candidate);
            } on SqliteException {/* Reread: commit may have succeeded. */}
            state = await _state();
            if (state.legacyAnchorJson == null) {
              _fault(
                ProblemCode.persistence,
                'Legacy freeze was not confirmed',
              );
            }
          }
          final anchor = state.legacyAnchorJson!;
          _anchorKind(anchor);
          // Each chunk freezes original locators and stable incarnations before any
          // later retry. No provider calls, file writes or Dumps updates in this loop.
          if (state.bootstrapVersion == 0) {
            while (true) {
              final count = await _db.transaction(() async {
                final rows = await _db
                    .customSelect(
                      'SELECT d.* FROM dumps d LEFT JOIN recording_bindings b ON b.dump_id=d.id WHERE b.dump_id IS NULL ORDER BY d.id LIMIT 64',
                    )
                    .get();
                for (final row in rows) {
                  final id = row.read<String>('id');
                  final audio = row.read<String>('audio_path');
                  final kind = RegExp(r'^content://', caseSensitive: false)
                          .hasMatch(audio)
                      ? 'saf'
                      : 'file';
                  await _db.into(_db.recordingBindings).insert(
                        RecordingBindingsCompanion.insert(
                          dumpId: id,
                          incarnation: 'legacy-$id',
                          audioJson: jsonEncode(
                            {'version': 1, 'kind': kind, 'value': audio},
                          ),
                          metadataName: '$id.meta.json',
                          legacyAnchorJson: Value(anchor),
                        ),
                      );
                }
                if (rows.isEmpty) {
                  await (_db.update(_db.storageCatalogStates)
                        ..where((s) => s.id.equals(1)))
                      .write(
                    const StorageCatalogStatesCompanion(
                      bootstrapVersion: Value(1),
                    ),
                  );
                }
                return rows.length;
              });
              if (count == 0) break;
            }
          }
          final problems = <StorageProblem>[];
          final unresolved = await (_db.select(_db.recordingBindings)
                ..where((b) => b.resolved.equals(false)))
              .get();
          final groups = <String, List<RecordingBindingRow>>{anchor: []};
          for (final row in unresolved) {
            if (row.legacyAnchorJson == null) {
              problems.add(
                (
                  code: ProblemCode.invalid,
                  message: 'Unresolved binding has no frozen source'
                ),
              );
              continue;
            }
            (groups[row.legacyAnchorJson!] ??= []).add(row);
          }
          for (final group in groups.entries) {
            try {
              _anchorKind(group.key);
              final legacy = _value(
                await _backend.inspectLegacyStorage(
                  filesystemLegacyDirectory: filesystemLegacyDirectory,
                  frozenAnchorJson: group.key,
                ),
              );
              if (legacy == null || legacy.anchorJson != group.key) {
                _fault(
                  ProblemCode.invalid,
                  'Resolution changed frozen authority',
                );
              }
              if (legacy.location == null) {
                _fault(
                  ProblemCode.unresolved,
                  'Original storage is unresolved',
                );
              }
              final location = legacy.location!;
              final entries =
                  _value(await _settled(_backend.listRecordingsAt(location)));
              final registered = await _db.transaction(() async {
                final stored = await _register(location, legacy: true);
                if (group.key == anchor) {
                  await (_db.update(_db.storageCatalogStates)
                        ..where(
                          (s) =>
                              s.id.equals(1) &
                              s.defaultLocationId.isNull() &
                              s.revision.equals(0),
                        ))
                      .write(
                    StorageCatalogStatesCompanion(
                      defaultLocationId: Value(stored.id),
                      revision: const Value(1),
                    ),
                  );
                }
                return stored;
              });
              for (final row in group.value) {
                try {
                  StorageCodec.validateLiteralId(row.dumpId);
                  final original = StorageCodec.decodeAudio(row.audioJson);
                  final matches =
                      entries.where((e) => e.id == row.dumpId).toList();
                  if (matches.length != 1 ||
                      matches.single.problem != null ||
                      !StorageCodec.sameAudioIdentity(
                        original,
                        matches.single.audio,
                      ) ||
                      StorageCodec.canonicalKey(
                            matches.single.source.directory,
                          ) !=
                          StorageCodec.canonicalKey(location.directory)) {
                    _fault(
                      ProblemCode.unresolved,
                      'Original audio ownership was not proven',
                    );
                  }
                  await _db.bindRecording(
                    (
                      key: (dumpId: row.dumpId, incarnation: row.incarnation),
                      location: registered,
                      audio: original,
                      metadataName: row.metadataName
                    ),
                  );
                } on StorageFault catch (e) {
                  problems.add(e.problem);
                }
              }
            } on StorageFault catch (e) {
              problems.add(e.problem);
            }
          }
          final remaining = await (_db.select(_db.recordingBindings)
                ..where((b) => b.resolved.equals(false)))
              .get();
          return (
            unresolvedIds: remaining.map((b) => b.dumpId).toList(),
            problems: problems
          );
        });
      });
}

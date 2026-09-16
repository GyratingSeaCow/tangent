// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart' show SqliteException;
import 'package:path/path.dart' as p;
import '../data/local_db.dart';
import '../data/recording_metadata.dart';
import '../data/storage/storage_codec.dart';
import '../data/storage/storage_contract.dart';
import 'recording_service.dart';

/// Reservation-owned publication journal. Never uses current default storage.
class RecordingPersistence {
  RecordingPersistence({
    required LocalDb db,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
  })  : _db = db,
        _backend = backend,
        _mutations = mutations;
  final LocalDb _db;
  final StorageBackend _backend;
  final RecordingMutationCoordinator _mutations;
  Never _fault(ProblemCode code, String message) =>
      throw StorageFault((code: code, message: message));
  T _value<T>(Outcome<T> value) => switch (value) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem)
      };
  Future<T> _runSettled<T>(
    UseLease lease,
    IoOperation<T> Function() start,
  ) async {
    IoOperation<T>? operation;
    try {
      return await _mutations.runIo(lease, () => operation = start());
    } finally {
      await operation?.settled;
    }
  }

  Future<CaptureReservationRow> _owned(
    CaptureReservation r, {
    bool requireEpoch = true,
  }) async {
    final row = await (_db.select(_db.captureReservations)
          ..where((s) => s.reservationId.equals(r.id)))
        .getSingleOrNull();
    if (row == null ||
        row.dumpId != r.key.dumpId ||
        row.incarnation != r.key.incarnation ||
        row.locationId != r.location.id ||
        row.stagingPath != r.stagingPath ||
        row.mode != r.mode ||
        row.startedAt != r.startedAt.millisecondsSinceEpoch) {
      _fault(ProblemCode.conflict, 'Capture reservation ownership changed');
    }
    final location = await (_db.select(_db.storageLocations)
          ..where((l) => l.id.equals(row.locationId)))
        .getSingle();
    if (requireEpoch && row.processEpoch != _mutations.processEpoch) {
      _fault(ProblemCode.conflict, 'Capture process ownership changed');
    }
    if (StorageCodec.decodeDirectory(location.directoryJson) !=
        r.location.directory) {
      _fault(ProblemCode.conflict, 'Capture destination changed');
    }
    return row;
  }

  Future<void> markState(
    CaptureReservation r,
    CapturePhase phase, {
    Map<String, dynamic>? journal,
  }) =>
      _db.transaction(() async {
        final row = await _owned(r);
        if (row.state == 'committed' && phase != CapturePhase.committed) return;
        await (_db.update(_db.captureReservations)
              ..where((s) => s.reservationId.equals(r.id)))
            .write(
          CaptureReservationsCompanion(
            state: Value(phase.name),
            publicationJson: journal == null
                ? const Value.absent()
                : Value(jsonEncode(journal)),
          ),
        );
      });
  Future<void> _staging(CaptureReservation r, int size) async {
    StorageCodec.encodeAudio((kind: 'file', value: r.stagingPath));
    if (p.basename(r.stagingPath) != '${r.id}.opus' ||
        await FileSystemEntity.type(r.stagingPath, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(
          await File(r.stagingPath).resolveSymbolicLinks(),
          p.normalize(p.absolute(r.stagingPath)),
        ) ||
        await File(r.stagingPath).length() != size ||
        size <= 0) {
      _fault(ProblemCode.invalid, 'Invalid owned staging source');
    }
  }

  Future<DumpRow> save(
    CaptureReservation r,
    RecordingResult result, {
    required DateTime now,
    required UseLease lease,
  }) async {
    if (result.path != r.stagingPath ||
        result.durationSeconds < 0 ||
        result.sizeBytes <= 0) {
      _fault(ProblemCode.invalid, 'Recorder result does not match reservation');
    }
    await _staging(r, result.sizeBytes);
    final staged = DumpRow(
      id: r.key.dumpId,
      createdAt: now.toUtc(),
      updatedAt: now.toUtc(),
      mode: r.mode,
      durationSeconds: result.durationSeconds,
      title: generatedRecordingTitle(now),
      audioPath: r.stagingPath,
      audioSizeBytes: result.sizeBytes,
      syncStatus: r.mode == 'meeting' ? 'local_only' : 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );
    final journal = <String, dynamic>{
      'version': 1,
      'stopped': {
        'path': result.path,
        'durationSeconds': result.durationSeconds,
        'sizeBytes': result.sizeBytes,
      },
      'metadata': dumpMetadata(staged),
      'published': null,
    };
    await markState(r, CapturePhase.stopped, journal: journal);
    return _publishAndCommit(r, journal, lease);
  }

  Future<DumpRow> _publishAndCommit(
    CaptureReservation r,
    Map<String, dynamic> journal,
    UseLease lease,
  ) async {
    final metadata = Map<String, dynamic>.from(journal['metadata'] as Map);
    validateImportedMetadata(r.key.dumpId, metadata);
    if (journal['published'] == null) {
      await markState(r, CapturePhase.publishing, journal: journal);
      final published = _value(
        await _runSettled(lease, () => _backend.publishCapture(r, metadata)),
      );
      StorageCodec.encodeBinding(published.binding);
      if (published.binding.key != r.key ||
          published.binding.location != r.location ||
          published.binding.metadataName != '${r.key.dumpId}.meta.json' ||
          published.sizeBytes != (journal['stopped'] as Map)['sizeBytes']) {
        _fault(
          ProblemCode.invalid,
          'Publication receipt does not match reserved ownership',
        );
      }
      journal['published'] = {
        'binding': StorageCodec.encodeBinding(published.binding),
        'sizeBytes': published.sizeBytes,
      };
      await markState(r, CapturePhase.publishing, journal: journal);
    }
    final receipt = journal['published'];
    if (receipt is! Map || receipt['binding'] is! String) {
      _fault(ProblemCode.invalid, 'Malformed owned publication receipt');
    }
    final binding = StorageCodec.decodeBinding(receipt['binding'] as String);
    if (binding.key != r.key ||
        binding.location != r.location ||
        receipt['sizeBytes'] is! int ||
        receipt['sizeBytes'] != (journal['stopped'] as Map)['sizeBytes']) {
      _fault(ProblemCode.invalid, 'Invalid owned publication receipt');
    }
    final durable = importedDumpRow(
      id: r.key.dumpId,
      locator: binding.audio.value,
      sizeBytes: receipt['sizeBytes'] as int,
      modifiedAt: r.startedAt,
      metadata: metadata,
    );
    // A receipt must refer to the exact regular entry in its reserved root.
    final entries = _value(
      await _runSettled(lease, () => _backend.listRecordingsAt(r.location)),
    );
    final matches = entries.where((e) => e.id == r.key.dumpId).toList();
    if (matches.length != 1 ||
        matches.single.problem != null ||
        StorageCodec.canonicalKey(matches.single.source.directory) !=
            StorageCodec.canonicalKey(r.location.directory) ||
        !StorageCodec.sameAudioIdentity(matches.single.audio, binding.audio) ||
        matches.single.sizeBytes != receipt['sizeBytes'] ||
        matches.single.metadata == null ||
        matches.single.metadata!.length != metadata.length ||
        !metadata.entries
            .every((e) => matches.single.metadata![e.key] == e.value)) {
      _fault(
        ProblemCode.invalid,
        'Published entry does not prove the owned receipt',
      );
    }
    late DumpRow saved;
    try {
      saved = await _db.commitOwnedCapture(() async {
        final owner = await _owned(r);
        final ticket = await (_db.select(_db.localDeletionTickets)
              ..where((t) => t.dumpId.equals(r.key.dumpId)))
            .getSingleOrNull();
        if (ticket != null) {
          _fault(
            ticket.state == 'completed'
                ? ProblemCode.retired
                : ProblemCode.fenced,
            'Capture identity fenced',
          );
        }
        final existing = await _db.getDump(r.key.dumpId);
        final existingBinding = await (_db.select(_db.recordingBindings)
              ..where((b) => b.dumpId.equals(r.key.dumpId)))
            .getSingleOrNull();
        if (existing != null || existingBinding != null) {
          if (owner.state != 'committed' ||
              existing == null ||
              await _db.boundRecording(r.key.dumpId) != binding ||
              existing.audioPath != binding.audio.value) {
            _fault(ProblemCode.conflict, 'Capture identity already claimed');
          }
          return existing;
        }
        await _db.into(_db.dumps).insert(durable);
        await _db.bindRecording(binding);
        await markState(r, CapturePhase.committed, journal: journal);
        return durable;
      });
    } on SqliteException {
      final owner = await _owned(r);
      final committed = await _db.getDump(r.key.dumpId);
      if (owner.state != 'committed' ||
          committed == null ||
          committed.audioPath != binding.audio.value ||
          await _db.boundRecording(r.key.dumpId) != binding) {
        rethrow;
      }
      saved = committed;
    }
    await cleanupCommitted(r, binding);
    return saved;
  }

  Future<OwnedCaptureRecoveryResult> recoverOwnedCaptures() async {
    final recovered = <String>[];
    final problems = <StorageProblem>[];
    for (final snapshot in await _db.select(_db.captureReservations).get()) {
      UseLease? lease;
      try {
        // A known stopped result is mandatory; abandoned recorder starts are not
        // audio-only imports, even if a file happens to be present.
        // Catalog owner replacement marks old stopped/publishing rows interrupted.
        // Only a coherent persisted stopped journal can distinguish them from an
        // interrupted recorder; a file alone never authorizes recovery.
        if (snapshot.publicationJson == null ||
            !const [
              'stopped',
              'publishing',
              'failed',
              'committed',
              'interrupted',
            ].contains(snapshot.state)) {
          continue;
        }
        final decoded = jsonDecode(snapshot.publicationJson!);
        if (decoded is! Map<String, dynamic> ||
            decoded['version'] != 1 ||
            decoded['stopped'] is! Map ||
            decoded['metadata'] is! Map) {
          _fault(ProblemCode.invalid, 'Malformed owned capture journal');
        }
        final stopped = decoded['stopped'] as Map;
        if (stopped['path'] != snapshot.stagingPath ||
            stopped['durationSeconds'] is! int ||
            (stopped['durationSeconds'] as int) < 0 ||
            stopped['sizeBytes'] is! int ||
            (stopped['sizeBytes'] as int) <= 0) {
          _fault(ProblemCode.invalid, 'No coherent stopped capture result');
        }
        final location = await (_db.select(_db.storageLocations)
              ..where((l) => l.id.equals(snapshot.locationId)))
            .getSingleOrNull();
        if (location == null) {
          _fault(ProblemCode.unresolved, 'Reserved location is unavailable');
        }
        final r = (
          id: snapshot.reservationId,
          key: (dumpId: snapshot.dumpId, incarnation: snapshot.incarnation),
          location: (
            id: location.id,
            directory: StorageCodec.decodeDirectory(location.directoryJson),
            label: location.label
          ),
          stagingPath: snapshot.stagingPath,
          mode: snapshot.mode,
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            snapshot.startedAt,
            isUtc: true,
          ),
          phase: CapturePhase.values.byName(snapshot.state)
        );
        validateImportedMetadata(
          r.key.dumpId,
          Map<String, dynamic>.from(decoded['metadata'] as Map),
        );
        final metadata = decoded['metadata'] as Map;
        if (metadata['mode'] != r.mode ||
            metadata['durationSeconds'] != stopped['durationSeconds'] ||
            metadata['audioSizeBytes'] != stopped['sizeBytes']) {
          _fault(ProblemCode.invalid, 'Stopped journal metadata is incoherent');
        }
        lease = _value(
          await _mutations.catalogAdmission(() => _mutations.acquire(
                r.key.dumpId,
                snapshot.state == 'committed'
                    ? UseKind.recovery
                    : UseKind.capture,
                expectedIncarnation: r.key.incarnation,
              ),),
        );
        await _mutations.serialize(r.key, () async {
          await _db.transaction(() async {
            final current = await _owned(r, requireEpoch: false);
            if (current.publicationJson != snapshot.publicationJson ||
                current.state != snapshot.state ||
                current.processEpoch != snapshot.processEpoch) {
              _fault(ProblemCode.conflict, 'Recovery journal changed');
            }
            await (_db.update(_db.captureReservations)
                  ..where((s) => s.reservationId.equals(r.id)))
                .write(
              CaptureReservationsCompanion(
                processEpoch: Value(_mutations.processEpoch),
              ),
            );
          });
          if (snapshot.state == 'committed') {
            final receipt = decoded['published'];
            if (receipt is! Map || receipt['binding'] is! String) {
              _fault(ProblemCode.invalid, 'Committed capture has no receipt');
            }
            final binding =
                StorageCodec.decodeBinding(receipt['binding'] as String);
            if (binding.key != r.key || binding.location != r.location) {
              _fault(
                ProblemCode.invalid,
                'Committed receipt ownership mismatch',
              );
            }
            await cleanupCommitted(r, binding);
          } else {
            if (decoded['published'] == null) {
              await _staging(r, stopped['sizeBytes'] as int);
            }
            await _publishAndCommit(r, decoded, lease!);
          }
        });
        recovered.add(r.key.dumpId);
      } on StorageFault catch (e) {
        problems.add(e.problem);
      } on SqliteException {
        problems.add(
          (
            code: ProblemCode.persistence,
            message: 'Owned capture persistence failed'
          ),
        );
      } on FileSystemException {
        problems.add(
          (
            code: ProblemCode.io,
            message: 'Owned capture cleanup or source unavailable'
          ),
        );
      } on FormatException {
        problems.add(
          (
            code: ProblemCode.invalid,
            message: 'Malformed owned capture journal'
          ),
        );
      } finally {
        await lease?.close();
      }
    }
    return (
      recoveredIds: recovered,
      retainedReservationIds: (await _db.select(_db.captureReservations).get())
          .map((r) => r.reservationId)
          .toList(),
      problems: problems
    );
  }

  Future<void> cleanupCommitted(
    CaptureReservation r,
    BoundRecording binding,
  ) async {
    Future<void> verify() async {
      final owner = await _owned(r);
      final row = await _db.getDump(r.key.dumpId);
      if (owner.state != 'committed' ||
          row == null ||
          row.audioPath != binding.audio.value ||
          await _db.boundRecording(r.key.dumpId) != binding) {
        _fault(
          ProblemCode.conflict,
          'Committed capture ownership not confirmed',
        );
      }
    }

    await _db.transaction(verify);
    final type = await FileSystemEntity.type(r.stagingPath, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file ||
          p.basename(r.stagingPath) != '${r.id}.opus' ||
          !p.equals(
            await File(r.stagingPath).resolveSymbolicLinks(),
            p.normalize(p.absolute(r.stagingPath)),
          )) {
        _fault(ProblemCode.invalid, 'Staging cleanup source is not owned');
      }
      await File(r.stagingPath).delete();
    }
    if (await FileSystemEntity.type(r.stagingPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _fault(ProblemCode.io, 'Staging cleanup remains pending');
    }
    await _db.transaction(() async {
      await verify();
      await (_db.delete(_db.captureReservations)
            ..where((s) => s.reservationId.equals(r.id)))
          .go();
    });
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'package:drift/drift.dart';
import 'package:drift/native.dart' show SqliteException;
import 'package:path/path.dart' as p;
import '../data/local_db.dart';
import '../data/recording_metadata.dart';
import '../data/storage/storage_codec.dart';
import '../data/storage/storage_contract.dart';
import 'package:crypto/crypto.dart';
import '../data/storage/capture_publication_codec.dart';
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
    final file = File(r.stagingPath);
    var valid = p.basename(r.stagingPath) ==
            '${r.id}.${contentExtensionForMode(r.mode)}' &&
        await FileSystemEntity.type(r.stagingPath, followLinks: false) ==
            FileSystemEntityType.file &&
        size > 0;
    var length = 0;
    if (valid) {
      valid = await _resolvesUnderOwnedParent(r.stagingPath);
    }
    if (valid) {
      try {
        length = await file.length();
      } on FileSystemException {
        valid = false;
      }
    }
    // The opus encoder may flush trailing bytes between the recorder's stop()
    // length capture and this validation. The on-disk length is authoritative
    // when it has not shrunk below the recorder-reported size.
    if (!valid || length < size) {
      _fault(ProblemCode.invalid, 'Invalid owned staging source');
    }
  }

  /// Same-file identity check tolerant of a symlink-aliased ancestor.
  ///
  /// Canonicalize BOTH sides: Android may hand out the staging directory
  /// through a symlinked alias (/data/user/0 vs /data/data), so comparing
  /// the file's resolved path against the literal reservation path rejects
  /// valid owned staging. Resolving the owned parent directory keeps the
  /// same-file identity check while accepting an aliased directory prefix.
  /// An entry that is itself a symlink resolves outside the owned parent
  /// and stays rejected (callers also require the literal entry to be a
  /// regular file with followLinks:false before consulting this check).
  /// Shared by _staging() and cleanupCommitted() so the two ownership
  /// predicates cannot drift apart again.
  Future<bool> _resolvesUnderOwnedParent(String stagingPath) async {
    try {
      final resolved = await File(stagingPath).resolveSymbolicLinks();
      final parent =
          await Directory(p.dirname(stagingPath)).resolveSymbolicLinks();
      return p.equals(resolved, p.join(parent, p.basename(stagingPath)));
    } on FileSystemException {
      return false;
    }
  }

  Map<String, dynamic> _object(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey)) {
      _fault(ProblemCode.invalid, 'Malformed capture handoff object');
    }
    return value;
  }

  bool _sameJson(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i).every((i) => _sameJson(a[i], b[i]));
    }
    return a == b;
  }

  Map<String, dynamic> _journal(CaptureReservation r, String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value['version'] is! int) {
      _fault(ProblemCode.invalid, 'Malformed owned capture journal');
    }
    if (value['version'] != 1 && value['version'] != 2) {
      _fault(ProblemCode.unsupported, 'Unknown owned capture journal version');
    }
    if (value['stopped'] is! Map<String, dynamic> ||
        value['metadata'] is! Map<String, dynamic>) {
      _fault(ProblemCode.invalid, 'Malformed stopped capture');
    }
    final stopped = value['stopped'] as Map<String, dynamic>;
    final metadata = value['metadata'] as Map<String, dynamic>;
    if (stopped['path'] != r.stagingPath ||
        stopped['durationSeconds'] is! int ||
        (stopped['durationSeconds'] as int) < 0 ||
        stopped['sizeBytes'] is! int ||
        (stopped['sizeBytes'] as int) <= 0) {
      _fault(ProblemCode.invalid, 'No coherent stopped capture result');
    }
    validateImportedMetadata(r.key.dumpId, metadata);
    if (metadata['mode'] != r.mode ||
        metadata['durationSeconds'] != stopped['durationSeconds'] ||
        metadata['audioSizeBytes'] != stopped['sizeBytes']) {
      _fault(ProblemCode.invalid, 'Stopped journal metadata is incoherent');
    }
    if (value['version'] == 2) {
      _object(
        value,
        {'version', 'stopped', 'metadata', 'handoff', 'published'},
      );
      _object(stopped, {'path', 'durationSeconds', 'sizeBytes'});
      final h = _object(value['handoff'], {
        'version',
        'publicationId',
        'reservationId',
        'key',
        'location',
        'stagingPath',
        'mode',
        'startedAtMs',
        'audioSha256',
        'metadataJson',
        'prepareOperationId',
        'stage',
        'preparation',
        'prepareResult',
      });
      if (h['version'] is! int || h['version'] != 1) {
        _fault(ProblemCode.unsupported, 'Unknown capture handoff version');
      }
      if (h['publicationId'] != r.id ||
          h['reservationId'] != r.id ||
          StorageCodec.decodeKey(jsonEncode(h['key'])) != r.key ||
          StorageCodec.decodeLocation(jsonEncode(h['location'])) !=
              r.location ||
          h['stagingPath'] != r.stagingPath ||
          h['mode'] != r.mode ||
          h['startedAtMs'] is! int ||
          h['startedAtMs'] != r.startedAt.millisecondsSinceEpoch ||
          r.startedAt.millisecondsSinceEpoch <= 0 ||
          h['audioSha256'] is! String ||
          h['metadataJson'] is! String ||
          h['prepareOperationId'] is! String) {
        _fault(ProblemCode.invalid, 'Frozen capture ownership differs');
      }
      CapturePublicationCodec.digest(h['audioSha256'] as String);
      CapturePublicationCodec.operationId(r, h['prepareOperationId'] as String);
      if (!_sameJson(
        CapturePublicationCodec.metadata(
          h['metadataJson'] as String,
          r.key.dumpId,
        ),
        metadata,
      )) {
        _fault(ProblemCode.invalid, 'Frozen capture metadata differs');
      }
      final stage = h['stage'];
      if (!const ['intent', 'preparing', 'prepared', 'initializing', 'complete']
          .contains(stage)) {
        _fault(ProblemCode.invalid, 'Unknown capture handoff stage');
      }
      final result = h['prepareResult'] == null
          ? null
          : CapturePublicationCodec.decodeResult(
              jsonEncode(h['prepareResult']),
            );
      final preparation = h['preparation'] == null
          ? null
          : CapturePublicationCodec.decodePreparation(
              jsonEncode(h['preparation']),
            );
      if (preparation != null) {
        CapturePublicationCodec.validateReservation(r, preparation);
        if (preparation.audioSizeBytes != stopped['sizeBytes'] ||
            preparation.audioSha256 != h['audioSha256'] ||
            preparation.metadataJson != h['metadataJson']) {
          _fault(
            ProblemCode.invalid,
            'Prepared payload differs from frozen intent',
          );
        }
      }
      if (!_sameJson(
        h['preparation'],
        result?.preparation == null
            ? null
            : jsonDecode(
                CapturePublicationCodec.encodePreparation(
                  result!.preparation!,
                ),
              ),
      )) {
        _fault(ProblemCode.invalid, 'Preparation and result disagree');
      }
      final ready =
          const ['prepared', 'initializing', 'complete'].contains(stage);
      if ((stage == 'intent' && result != null) ||
          (stage == 'preparing' &&
              result?.state == CapturePreparationState.prepared) ||
          (ready && result?.state != CapturePreparationState.prepared) ||
          (ready &&
              (preparation?.audio == null || preparation?.metadata == null)) ||
          ((stage == 'complete') != (value['published'] != null))) {
        _fault(ProblemCode.invalid, 'Incoherent capture checkpoint');
      }
    }
    final receipt = value['published'];
    if (receipt != null) {
      final receiptMap = _object(receipt, {'binding', 'sizeBytes'});
      if (receiptMap['binding'] is! String ||
          receiptMap['sizeBytes'] is! int ||
          receiptMap['sizeBytes'] != stopped['sizeBytes']) {
        _fault(ProblemCode.invalid, 'Malformed capture receipt');
      }
      final binding =
          StorageCodec.decodeBinding(receiptMap['binding'] as String);
      if (binding.key != r.key ||
          binding.location != r.location ||
          binding.metadataName != '${r.key.dumpId}.meta.json') {
        _fault(ProblemCode.invalid, 'Receipt ownership differs');
      }
      if (value['version'] == 2) {
        final prepared = CapturePublicationCodec.decodePreparation(
          jsonEncode((value['handoff'] as Map)['preparation']),
        );
        if (binding.audio != prepared.audio!.locator) {
          _fault(ProblemCode.invalid, 'Receipt is not the prepared object');
        }
      }
    }
    return value;
  }

  Future<CaptureReservationRow> _current(
    CaptureReservation r,
    String raw,
  ) async {
    final row = await _owned(r);
    if (row.publicationJson != raw ||
        !const ['stopped', 'publishing', 'failed', 'interrupted']
            .contains(row.state)) {
      _fault(ProblemCode.conflict, 'Capture checkpoint ownership changed');
    }
    return row;
  }

  Future<String> _checkpoint(
    CaptureReservation r,
    CaptureReservationRow prior,
    Map<String, dynamic> journal,
    CapturePhase phase,
  ) async {
    final next = jsonEncode(journal);
    _journal(r, next);
    try {
      await _db.transaction(() async {
        final owner = await _owned(r);
        if (owner.publicationJson != prior.publicationJson ||
            owner.state != prior.state ||
            owner.processEpoch != prior.processEpoch ||
            owner.state == 'committed') {
          _fault(ProblemCode.conflict, 'Capture checkpoint was superseded');
        }
        await (_db.update(_db.captureReservations)
              ..where((s) => s.reservationId.equals(r.id)))
            .write(
          CaptureReservationsCompanion(
            state: Value(phase.name),
            publicationJson: Value(next),
          ),
        );
      });
    } on SqliteException {
      // An uncertain acknowledgement is not permission to issue more I/O.
      final readback = await _owned(r);
      if (readback.publicationJson != next || readback.state != phase.name) {
        rethrow;
      }
    }
    final readback = await _owned(r);
    if (readback.publicationJson != next || readback.state != phase.name) {
      _fault(ProblemCode.conflict, 'Capture checkpoint readback differs');
    }
    _journal(r, readback.publicationJson!);
    return readback.publicationJson!;
  }

  Future<String> _completeCapture(
    CaptureReservation r,
    String raw,
    UseLease lease,
  ) async {
    var journal = _journal(r, raw);
    if (journal['version'] == 1 && journal['published'] == null) {
      _fault(ProblemCode.unresolved, 'Legacy capture has no ownership receipt');
    }
    final prior = await _current(r, raw);
    if (prior.state != 'publishing') {
      raw = await _checkpoint(r, prior, journal, CapturePhase.publishing);
      journal = _journal(r, raw);
    }
    if (journal['version'] == 1) {
      return raw;
    }
    var h = journal['handoff'] as Map<String, dynamic>;
    var dispatch = false;
    if (h['stage'] == 'intent') {
      final prior = await _current(r, raw);
      h['stage'] = 'preparing';
      raw = await _checkpoint(r, prior, journal, CapturePhase.publishing);
      journal = _journal(r, raw);
      h = journal['handoff'] as Map<String, dynamic>;
      dispatch = true;
    }
    if (h['stage'] == 'preparing') {
      if (h['prepareResult'] == null) {
        await _current(r, raw);
        final result = await _runSettled(
          lease,
          () => _backend.prepareCapture(
            r,
            h['metadataJson'] as String,
            h['audioSha256'] as String,
            h['prepareOperationId'] as String,
            observeOnly: !dispatch,
          ),
        );
        // Strict validation precedes persistence and any acknowledgement.
        final encoded = CapturePublicationCodec.encodeResult(result);
        final prior = await _current(r, raw);
        h['prepareResult'] = jsonDecode(encoded);
        h['preparation'] = result.preparation == null
            ? null
            : jsonDecode(
                CapturePublicationCodec.encodePreparation(result.preparation!),
              );
        if (result.state == CapturePreparationState.prepared) {
          h['stage'] = 'prepared';
        }
        raw = await _checkpoint(r, prior, journal, CapturePhase.publishing);
        journal = _journal(r, raw);
        h = journal['handoff'] as Map<String, dynamic>;
      }
    }
    // Only the owner which reread the exact result may release retention. A lost
    // acknowledgement is not a failed publication; durable claims are authority.
    if (h['prepareResult'] != null) {
      await _current(r, raw);
      try {
        await _backend
            .acknowledgeCapturePreparation(h['prepareOperationId'] as String);
      } catch (_) {/* durable evidence retained */}
    }
    if (h['stage'] == 'preparing') {
      final result =
          CapturePublicationCodec.decodeResult(jsonEncode(h['prepareResult']));
      throw StorageFault(
        result.problem ??
            (
              code: ProblemCode.unresolved,
              message: 'Preparation is unresolved'
            ),
      );
    }
    if (h['stage'] == 'prepared') {
      final prior = await _current(r, raw);
      h['stage'] = 'initializing';
      raw = await _checkpoint(r, prior, journal, CapturePhase.publishing);
      journal = _journal(r, raw);
      h = journal['handoff'] as Map<String, dynamic>;
    }
    final preparation =
        CapturePublicationCodec.decodePreparation(jsonEncode(h['preparation']));
    Future<CaptureInspection> inspect() async {
      await _current(r, raw);
      return _value(
        await _runSettled(
          lease,
          () => _backend.inspectPreparedCapture(r, preparation),
        ),
      );
    }

    bool complete(CaptureInspection value) =>
        value.audio.state == CaptureContentState.complete &&
        value.metadata.state == CaptureContentState.complete;
    final observation = await inspect();
    if (!complete(observation)) {
      if (h['stage'] == 'complete' ||
          ![observation.audio, observation.metadata].every(
            (c) =>
                c.state == CaptureContentState.empty ||
                c.state == CaptureContentState.complete,
          )) {
        for (final component in [observation.audio, observation.metadata]) {
          final problem = component.problem;
          // A missing claim remains unresolved; never recreate it. Preserve
          // stronger conflict/permission/provider diagnostics rather than
          // flattening all observations into a generic partial-content fault.
          if (problem != null && problem.code != ProblemCode.absent) {
            throw StorageFault(problem);
          }
        }
        _fault(
          ProblemCode.unresolved,
          'Prepared components are partial, foreign or unavailable',
        );
      }
      await _current(r, raw);
      final published = _value(
        await _runSettled(
          lease,
          () => _backend.publishPreparedCapture(r, preparation),
        ),
      );
      if (published.binding !=
              (
                key: r.key,
                location: r.location,
                audio: preparation.audio!.locator,
                metadataName: preparation.metadata!.name
              ) ||
          published.sizeBytes != preparation.audioSizeBytes) {
        _fault(ProblemCode.invalid, 'Prepared publication receipt differs');
      }
      // No post-publish inspection here. publishPreparedCapture already reads
      // both components back and compares them byte-for-byte natively before
      // returning, and its receipt (checked directly above) carries the
      // binding and byte size. Re-reading the whole file over SAF to confirm
      // the confirmation cost 352ms on a 90-second recording and grows with
      // real audio content. See docs/.../2026-09-17-iteration-4.md.
    }
    if (h['stage'] != 'complete') {
      final prior = await _current(r, raw);
      h['stage'] = 'complete';
      journal['published'] = {
        'binding': StorageCodec.encodeBinding(
          (
            key: r.key,
            location: r.location,
            audio: preparation.audio!.locator,
            metadataName: preparation.metadata!.name
          ),
        ),
        'sizeBytes': preparation.audioSizeBytes,
      };
      raw = await _checkpoint(r, prior, journal, CapturePhase.publishing);
    }
    return raw;
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
    final prior = await _owned(r);
    if (prior.publicationJson != null ||
        !const ['reserved', 'recording'].contains(prior.state)) {
      _fault(ProblemCode.conflict, 'Capture already has a stopped handoff');
    }
    await _staging(r, result.sizeBytes);
    // One streaming pass supplies both the frozen digest and the
    // authoritative length, so the journal can never pair a digest with a
    // different byte count — without buffering a long recording in memory.
    Digest? digestValue;
    final byteSink = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
        (digests) => digestValue = digests.single,
      ),
    );
    // A text note IS its staged bytes: the journal metadata must carry the
    // body as transcript so recovery restores it. Notes are small; audio is
    // never buffered.
    final isNote = r.mode == 'text_note';
    final noteBytes = isNote ? BytesBuilder(copy: false) : null;
    var sizeBytes = 0;
    await for (final chunk in File(r.stagingPath).openRead()) {
      sizeBytes += chunk.length;
      byteSink.add(chunk);
      noteBytes?.add(chunk);
    }
    byteSink.close();
    if (sizeBytes < result.sizeBytes) {
      _fault(ProblemCode.invalid, 'Invalid owned staging source');
    }
    final digest = digestValue!.toString();
    final staged = DumpRow(
      id: r.key.dumpId,
      createdAt: now.toUtc(),
      updatedAt: now.toUtc(),
      mode: r.mode,
      durationSeconds: result.durationSeconds,
      title: isNote ? generatedNoteTitle(now) : generatedRecordingTitle(now),
      transcript: isNote ? utf8.decode(noteBytes!.takeBytes()) : null,
      audioPath: r.stagingPath,
      audioSizeBytes: sizeBytes,
      syncStatus: r.mode == 'meeting' ? 'local_only' : 'pending',
      syncAttempts: 0,
      transcriptionStatus: isNote ? 'not_applicable' : 'not_transcribed',
      transcriptionAttempt: 0,
    );
    final metadata = dumpMetadata(staged);
    final journal = <String, dynamic>{
      'version': 2,
      'stopped': {
        'path': result.path,
        'durationSeconds': result.durationSeconds,
        'sizeBytes': sizeBytes,
      },
      'metadata': metadata,
      'handoff': {
        'version': 1,
        'publicationId': r.id,
        'reservationId': r.id,
        'key': jsonDecode(StorageCodec.encodeKey(r.key)),
        'location': jsonDecode(StorageCodec.encodeLocation(r.location)),
        'stagingPath': r.stagingPath,
        'mode': r.mode,
        'startedAtMs': r.startedAt.millisecondsSinceEpoch,
        'audioSha256': digest,
        'metadataJson': jsonEncode(metadata),
        'prepareOperationId': 'capture-${r.id}-prepare',
        'stage': 'intent',
        'preparation': null,
        'prepareResult': null,
      },
      'published': null,
    };
    final raw = await _checkpoint(r, prior, journal, CapturePhase.stopped);
    return _publishAndCommit(r, raw, lease);
  }

  Future<DumpRow> _publishAndCommit(
    CaptureReservation r,
    String raw,
    UseLease lease,
  ) async {
    raw = await _completeCapture(r, raw, lease);
    final journal = _journal(r, raw);
    final metadata = Map<String, dynamic>.from(journal['metadata'] as Map);
    validateImportedMetadata(r.key.dumpId, metadata);
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
    //
    // Read only THAT entry when the backend can: proving one receipt by
    // enumerating and parsing every recording in the folder cost 4.4s of a
    // 5.9s stop with 56 recordings (T8). Falls back to the full listing when
    // the backend cannot answer for a single entry, so behaviour is unchanged
    // everywhere else. Nothing is cached — the entry is still re-read from
    // storage, so the proof is exactly as strong.
    final single = _backend.readRecordingAt(r.location, r.key.dumpId);
    final List<ImportedEntry> matches;
    if (single != null) {
      final entry = _value(await _runSettled(lease, () => single));
      matches = <ImportedEntry>[if (entry != null) entry];
    } else {
      final entries = _value(
        await _runSettled(lease, () => _backend.listRecordingsAt(r.location)),
      );
      matches = entries.where((e) => e.id == r.key.dumpId).toList();
    }
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
        if (owner.publicationJson != raw ||
            !const [
              'stopped',
              'publishing',
              'failed',
              'interrupted',
              'committed',
            ].contains(owner.state)) {
          _fault(ProblemCode.conflict, 'Capture changed before row commit');
        }
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
    // The capture is durably committed at this point; recoverOwnedCaptures()
    // reconciles any leftover committed reservation + staged file on the next
    // launch. A cleanup fault therefore must not surface as a save failure —
    // the recording IS saved, and the UI caller reports any exception from
    // this path as "Recording failed". Swallow only cleanup-scoped faults;
    // real corruption (ownership/binding mismatch) was already verified by
    // cleanupCommitted's own pre-delete transaction before this can throw.
    try {
      await cleanupCommitted(r, binding);
    } on StorageFault {
      // Deferred to recoverOwnedCaptures(); the committed row is authoritative.
    } on FileSystemException {
      // Same: staging deletion is retried by recovery, never blocks the save.
    }
    return saved;
  }

  Future<void> _recordRecoveryFailure(CaptureReservation r) async {
    try {
      await _db.transaction(() async {
        final owner = await _owned(r);
        // Only this recovery's active phases may become failed. Never demote a
        // committed journal, a recorder restart, or another process's owner.
        if (owner.state != 'stopped' && owner.state != 'publishing') return;
        await (_db.update(_db.captureReservations)
              ..where((s) => s.reservationId.equals(r.id)))
            .write(const CaptureReservationsCompanion(state: Value('failed')));
      });
    } on SqliteException {
      // Retain the original diagnostic and durable journal if this write fails.
    } on StorageFault {
      // Ownership was replaced; the obsolete recovery cannot change it.
    } on FormatException {
      // A changed destination cannot authorize a failure-state write.
    } on StateError {
      // A removed destination likewise leaves no authority to update the owner.
    }
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
        _journal(r, snapshot.publicationJson!);
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
          await _mutations.catalogAdmission(
            () => _mutations.acquire(
              r.key.dumpId,
              snapshot.state == 'committed'
                  ? UseKind.recovery
                  : UseKind.capture,
              expectedIncarnation: r.key.incarnation,
            ),
          ),
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
          try {
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
              await _publishAndCommit(r, snapshot.publicationJson!, lease!);
            }
          } catch (_) {
            // _runSettled has joined every issued I/O operation. Keep the live
            // lease and per-key serializer until the guarded failure is durable.
            await _recordRecoveryFailure(r);
            rethrow;
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
      // Same aliased-ancestor tolerance as _staging(); see
      // _resolvesUnderOwnedParent. A symlink entry has type link (not file)
      // under followLinks:false and is rejected before resolution runs.
      final owned = type == FileSystemEntityType.file &&
          p.basename(r.stagingPath) ==
              '${r.id}.${contentExtensionForMode(r.mode)}' &&
          await _resolvesUnderOwnedParent(r.stagingPath);
      if (!owned) {
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

// SPDX-License-Identifier: AGPL-3.0-or-later
// Independent Flutter worker processes; only the synthetic fixture path crosses.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/capture_publication_codec.dart';
import 'package:tangent/data/storage/filesystem_capture_io.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';
import 'storage_fixture.dart';

class _Operation<T> implements IoOperation<T> {
  _Operation(this.id, Future<T> Function() action) {
    result = Future<T>.sync(action).whenComplete(() => _done.complete());
  }
  @override
  final String id;
  @override
  late final Future<T> result;
  final _done = Completer<void>();
  @override
  Future<void> get settled => _done.future;
}

CaptureObjectIdentity _identity(String path) {
  final h = openCaptureHandle(path);
  try {
    return h.identity;
  } finally {
    h.close();
  }
}

class _CrashBackend extends FilesystemStorageBackend {
  _CrashBackend(this.db, this.root, this.boundary);
  final LocalDb db;
  final String root, boundary;
  Future<Never> crash(CaptureReservation r, PreparedCapture prep) async {
    final row = await db.select(db.captureReservations).getSingle();
    final j = jsonDecode(row.publicationJson!) as Map;
    expect(j['published'], isNull);
    expect(
      (j['handoff'] as Map)['stage'],
      boundary == 'created' ? 'preparing' : 'initializing',
    );
    expect(await db.select(db.dumps).get(), isEmpty);
    expect(await db.select(db.recordingBindings).get(), isEmpty);
    if (boundary == 'created') {
      expect((j['handoff'] as Map)['preparation'], isNull);
    } else {
      expect(
        (j['handoff'] as Map)['preparation'],
        jsonDecode(CapturePublicationCodec.encodePreparation(prep)),
      );
    }
    final observed =
        requireOk(await settled(super.inspectPreparedCapture(r, prep)));
    final state = boundary == 'complete'
        ? CaptureContentState.complete
        : CaptureContentState.empty;
    expect(observed.audio.state, state);
    expect(observed.metadata.state, state);
    // Evidence is read only AFTER production recovery, never as its authority.
    File(p.join(root, 'before.json')).writeAsStringSync(
      jsonEncode({
        'pid': pid,
        'boundary': boundary,
        'dumpId': r.key.dumpId,
        'stagingPath': r.stagingPath,
        'startedAtMs': r.startedAt.millisecondsSinceEpoch,
        'audioPath': prep.audio!.locator.value,
        'metadataPath': prep.metadata!.locator.value,
        'journal': row.publicationJson,
        'audioIdentity': CapturePublicationCodec.identityMap(
          _identity(prep.audio!.locator.value),
        ),
        'metadataIdentity': CapturePublicationCodec.identityMap(
          _identity(prep.metadata!.locator.value),
        ),
        'audioBytes':
            base64Encode(File(prep.audio!.locator.value).readAsBytesSync()),
        'metadataBytes':
            base64Encode(File(prep.metadata!.locator.value).readAsBytesSync()),
      }),
      flush: true,
    );
    stdout.writeln('PHASE_B_ABRUPT_EXIT boundary=$boundary pid=$pid');
    await stdout.flush();
    exit(73); // Deliberately no finally/close/lease release/receipt transfer.
  }

  @override
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation r,
    String metadata,
    String digest,
    String id, {
    required bool observeOnly,
  }) =>
      _Operation(id, () async {
        final result = await settled(
          super.prepareCapture(r, metadata, digest, id,
              observeOnly: observeOnly,),
        );
        if (boundary == 'created') {
          expect(result.state, CapturePreparationState.prepared);
          await crash(r, result.preparation!);
        }
        return result;
      });
  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture prep,
  ) =>
      _Operation('fixture-crash-write', () async {
        if (boundary == 'prepared') await crash(r, prep);
        final result = await settled(super.publishPreparedCapture(r, prep));
        requireOk(
          result,
        ); // Real production write/readback, never fabricated success.
        await crash(r, prep);
      });
}

class _ColdBackend extends FilesystemStorageBackend {
  _ColdBackend(this.boundary);
  final String boundary;
  int inspections = 0, observations = 0, writes = 0;
  @override
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation r,
    String metadata,
    String digest,
    String id, {
    required bool observeOnly,
  }) {
    if (boundary != 'created' || !observeOnly) {
      throw StateError('Cold recovery must not CREATE');
    }
    observations++;
    return super.prepareCapture(r, metadata, digest, id, observeOnly: true);
  }

  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture prep,
  ) {
    if (boundary != 'prepared') {
      throw StateError('Cold complete/unknown recovery must not write');
    }
    writes++;
    return super.publishPreparedCapture(r, prep);
  }

  @override
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(
    CaptureReservation r,
    PreparedCapture prep,
  ) {
    inspections++;
    return super.inspectPreparedCapture(r, prep);
  }
}

void main() {
  test('phaseB true process handoff', () async {
    final root = Platform.environment['TANGENT_HANDOFF_ROOT'];
    final mode = Platform.environment['TANGENT_HANDOFF_MODE'];
    final boundary = Platform.environment['TANGENT_HANDOFF_BOUNDARY'];
    if (root == null ||
        !p.basename(root).startsWith('tangent-phase-b-') ||
        !const ['crash', 'recover'].contains(mode) ||
        !const ['created', 'prepared', 'complete'].contains(boundary)) {
      throw StateError('Requires explicit synthetic process fixture');
    }
    final db = LocalDb.forTesting(
      NativeDatabase(File(p.join(root, 'fixture.sqlite'))),
    );
    final backend = mode == 'crash'
        ? _CrashBackend(db, root, boundary!)
        : _ColdBackend(boundary!);
    final mutations = DefaultRecordingMutationCoordinator(db: db);
    var n = 0;
    final catalog = SqliteStorageCatalog(
      db: db,
      backend: backend,
      mutations: mutations,
      stagingDirectory: p.join(root, 'stage'),
      idFactory: () => 'fixture-process-${n++}',
      now: () => DateTime.utc(2030, 1, 2, 3, 4, 5, 123),
      canChooseDefault: true,
    );
    requireOk(
      await catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: p.join(root, 'A'),
      ),
    );
    final owner =
        RecordingPersistence(db: db, backend: backend, mutations: mutations);
    if (mode == 'crash') {
      final r = requireOk(await catalog.reserveCapture(mode: 'meeting'));
      File(r.stagingPath).writeAsBytesSync([1, 2, 3, 4, 5], flush: true);
      final lease = requireOk(
        await mutations.acquire(
          r.key.dumpId,
          UseKind.capture,
          expectedIncarnation: r.key.incarnation,
        ),
      );
      await mutations.serialize(
        r.key,
        () => owner.save(
          r,
          RecordingResult(
            path: r.stagingPath,
            durationSeconds: 3,
            sizeBytes: 5,
          ),
          now: DateTime.utc(2030, 1, 2, 3, 4, 5, 123),
          lease: lease,
        ),
      );
      fail('Abrupt boundary not reached');
    } else {
      final snapshot = await db.select(db.captureReservations).getSingle();
      expect(await db.select(db.dumps).get(), isEmpty);
      final result =
          await owner.recoverOwnedCaptures(); // No before.json input.
      final cold = backend as _ColdBackend;
      if (boundary == 'created') {
        expect(result.recoveredIds, isEmpty);
        expect(result.retainedReservationIds, [snapshot.reservationId]);
        expect(result.problems.single.code, ProblemCode.unresolved);
        expect(cold.observations, 1);
        expect(cold.writes, 0);
        expect(cold.inspections, 0);
        expect(await db.select(db.dumps).get(), isEmpty);
        expect(await db.select(db.recordingBindings).get(), isEmpty);
        expect(File(snapshot.stagingPath).readAsBytesSync(), [1, 2, 3, 4, 5]);
      } else {
        expect(result.problems, isEmpty);
        expect(result.recoveredIds, [snapshot.dumpId]);
        expect(result.retainedReservationIds, isEmpty);
        expect(cold.observations, 0);
        expect(cold.writes, boundary == 'prepared' ? 1 : 0);
        expect(cold.inspections, boundary == 'prepared' ? 2 : 1);
        expect(await db.select(db.dumps).get(), hasLength(1));
        expect(await db.select(db.recordingBindings).get(), hasLength(1));
        expect(File(snapshot.stagingPath).existsSync(), isFalse);
      }
      final evidence =
          jsonDecode(File(p.join(root, 'before.json')).readAsStringSync())
              as Map;
      expect(pid, isNot(evidence['pid']));
      expect(snapshot.startedAt, evidence['startedAtMs']);
      expect(snapshot.startedAt % 1000, 123);
      expect(snapshot.publicationJson, evidence['journal']);
      final audio = evidence['audioPath'] as String,
          meta = evidence['metadataPath'] as String;
      expect(
        CapturePublicationCodec.identityMap(_identity(audio)),
        evidence['audioIdentity'],
      );
      expect(
        CapturePublicationCodec.identityMap(_identity(meta)),
        evidence['metadataIdentity'],
      );
      if (boundary != 'prepared') {
        expect(
          base64Encode(File(audio).readAsBytesSync()),
          evidence['audioBytes'],
        );
        expect(
          base64Encode(File(meta).readAsBytesSync()),
          evidence['metadataBytes'],
        );
      } else {
        expect(File(audio).readAsBytesSync(), [1, 2, 3, 4, 5]);
        final h =
            (jsonDecode(snapshot.publicationJson!) as Map)['handoff'] as Map;
        expect(
          File(meta).readAsBytesSync(),
          utf8.encode(h['metadataJson'] as String),
        );
      }
      if (boundary != 'created') {
        expect((await db.boundRecording(snapshot.dumpId))!.audio.value, audio);
      }
      await backend.drain();
      await mutations.drain();
      await db.close();
      stdout.writeln(
        'PHASE_B_COLD_RECOVERY_VERIFIED boundary=$boundary pid=$pid',
      );
    }
  });
}

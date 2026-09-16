// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/capture_publication_codec.dart';
import 'package:tangent/data/storage/filesystem_capture_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/recording_importer.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

IoOperation<T> observedIo<T>(Future<T> Function() action) {
  final done = Completer<void>();
  final result = Future<T>.sync(action).whenComplete(done.complete);
  return GatedIo('fixture-owner-observation', result, done.future);
}

class CheckpointAckDb extends LocalDb {
  CheckpointAckDb(super.executor) : super.forTesting();
  String? loseStage;
  bool lost = false;
  int depth = 0;
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    depth++;
    late T result;
    try {
      result = await super.transaction(action, requireNew: requireNew);
    } finally {
      depth--;
    }
    if (depth == 0 && loseStage != null && !lost) {
      final row = await select(captureReservations).getSingle();
      final stage = row.publicationJson == null
          ? null
          : (jsonDecode(row.publicationJson!)['handoff'] as Map)['stage'];
      if (stage == loseStage) {
        lost = true;
        throw SqliteException(
          10,
          'fixture checkpoint committed, response lost',
        );
      }
    }
    return result;
  }
}

class OwnerWitnessBackend extends FilesystemStorageBackend {
  OwnerWitnessBackend(this.db);
  final LocalDb db;
  Future<void> Function()? beforeList;
  @override
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(
          StorageLocation location,) =>
      observedIo(() async {
        final operation = super.listRecordingsAt(location);
        final result = await operation.result;
        await operation.settled;
        await beforeList?.call();
        return result;
      });
  int creates = 0, observations = 0, initializations = 0, acknowledgements = 0;
  bool loseResponse = false,
      loseAcknowledgement = false,
      stopBeforeWrite = false,
      stopBeforePrepare = false,
      uncertainResult = false;
  Future<Map<String, dynamic>> journal() async => jsonDecode(
        (await db.select(db.captureReservations).getSingle()).publicationJson!,
      ) as Map<String, dynamic>;
  @override
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation r,
    String metadata,
    String digest,
    String id, {
    required bool observeOnly,
  }) =>
      observedIo(() async {
        final h = (await journal())['handoff'] as Map;
        expect(h['stage'], 'preparing');
        expect(h['prepareOperationId'], id);
        expect(h['metadataJson'], metadata);
        expect(h['audioSha256'], digest);
        if (observeOnly) {
          observations++;
        } else {
          creates++;
        }
        if (stopBeforePrepare && !observeOnly) {
          throw const StorageFault(
            (code: ProblemCode.io, message: 'fixture before dispatch'),
          );
        }
        final result = await settled(
          super.prepareCapture(
            r,
            metadata,
            digest,
            id,
            observeOnly: observeOnly,
          ),
        );
        if (uncertainResult) {
          expect(result.state, CapturePreparationState.prepared);
          final p = result.preparation!;
          return (
            state: CapturePreparationState.uncertain,
            preparation: (
              publicationId: p.publicationId,
              reservationId: p.reservationId,
              key: p.key,
              location: p.location,
              stagingPath: p.stagingPath,
              sourceIdentity: p.sourceIdentity,
              rootIdentity: p.rootIdentity,
              audioSizeBytes: p.audioSizeBytes,
              audioSha256: p.audioSha256,
              metadataJson: p.metadataJson,
              audio: p.audio,
              metadata: null
            ),
            rawReturnedLocators: result.rawReturnedLocators,
            problem: (
              code: ProblemCode.unavailable,
              message: 'fixture second claim query unavailable'
            )
          );
        }
        return result;
      });
  @override
  Future<Outcome<void>> acknowledgeCapturePreparation(String id) async {
    final h = (await journal())['handoff'] as Map;
    expect(h['prepareResult'], isNotNull);
    expect(h['prepareOperationId'], id);
    acknowledgements++;
    if (loseAcknowledgement) {
      return const Fail((code: ProblemCode.io, message: 'fixture lost ack'));
    }
    return super.acknowledgeCapturePreparation(id);
  }

  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) =>
      observedIo(() async {
        final h = (await journal())['handoff'] as Map;
        expect(h['stage'], 'initializing');
        expect(
          h['preparation'],
          jsonDecode(CapturePublicationCodec.encodePreparation(preparation)),
        );
        initializations++;
        if (stopBeforeWrite) {
          return const Fail(
            (code: ProblemCode.io, message: 'fixture before first write'),
          );
        }
        final result =
            await settled(super.publishPreparedCapture(r, preparation));
        if (loseResponse) {
          requireOk(result);
          return const Fail(
            (code: ProblemCode.io, message: 'fixture lost real write response'),
          );
        }
        return result;
      });
}

Future<CaptureReservation> begin(CatalogHarness h) async {
  await h.bootstrap();
  final r = requireOk(await h.catalog.reserveCapture(mode: 'meeting'));
  await File(r.stagingPath).writeAsBytes([1, 2, 3], flush: true);
  return r;
}

Future<DumpRow> saveWith(
  CatalogHarness h,
  CaptureReservation r,
  StorageBackend backend,
) async {
  final lease = requireOk(
    await h.mutations.acquire(
      r.key.dumpId,
      UseKind.capture,
      expectedIncarnation: r.key.incarnation,
    ),
  );
  try {
    return await h.mutations.serialize(
      r.key,
      () => RecordingPersistence(
        db: h.f.db,
        backend: backend,
        mutations: h.mutations,
      ).save(
        r,
        RecordingResult(
          path: r.stagingPath,
          durationSeconds: 3,
          sizeBytes: 3,
        ),
        now: DateTime.utc(2030, 1, 2, 3, 4, 5, 123),
        lease: lease,
      ),
    );
  } finally {
    await lease.close();
  }
}

void main() {
  for (final state in ['claimed', 'completed']) {
    test('v2 late $state deletion ticket blocks atomic row commit', () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      final r = await begin(h);
      final backend = OwnerWitnessBackend(h.f.db);
      backend.beforeList = () async {
        final receipt = (await backend.journal())['published'] as Map;
        await h.f.db.customStatement(
          'INSERT INTO local_deletion_tickets(dump_id,incarnation,ticket_id,operation_id,binding_json,audio_state,metadata_state,state) VALUES(?,?,?,?,?,?,?,?)',
          [
            r.key.dumpId,
            r.key.incarnation,
            'fixture-ticket',
            'fixture-operation',
            receipt['binding'],
            'pending',
            'pending',
            state,
          ],
        );
      };
      await expectLater(
        saveWith(h, r, backend),
        throwsA(isA<StorageFault>().having(
            (e) => e.problem.code,
            'ticket fence',
            state == 'completed' ? ProblemCode.retired : ProblemCode.fenced,),),
      );
      expect(await h.f.db.getDump(r.key.dumpId), isNull);
      expect(await h.f.db.boundRecording(r.key.dumpId), isNull);
      expect(await File(r.stagingPath).exists(), isTrue);
      expect((await backend.journal())['published'], isNotNull);
      expect(
          await h.f.db
              .select(h.f.db.localDeletionTickets)
              .getSingle()
              .then((t) => t.state),
          state,);
    });
  }

  for (final stage in [
    'intent',
    'preparing',
    'prepared',
    'initializing',
    'complete',
  ]) {
    test(
        'v2 $stage transaction acknowledgement loss rereads exact committed winner',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await h.f.db.close();
      final db = CheckpointAckDb(
        NativeDatabase(File('${h.f.root.path}/fixture.sqlite')),
      );
      h.f.db = db;
      h.resetOwners();
      final r = await begin(h);
      db.loseStage = stage;
      final backend = OwnerWitnessBackend(db);
      final row = await saveWith(h, r, backend);
      expect(db.lost, isTrue);
      expect(row.id, r.key.dumpId);
      expect(backend.creates, 1);
      expect(backend.initializations, 1);
      expect(await db.select(db.dumps).get(), hasLength(1));
      expect(await db.select(db.captureReservations).get(), isEmpty);
    });
  }
  test('v2 partial receipt and every raw return remain durable without content',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final r = await begin(h);
    final backend = OwnerWitnessBackend(h.f.db)..uncertainResult = true;
    await expectLater(saveWith(h, r, backend), throwsA(isA<StorageFault>()));
    final before = await backend.journal();
    final handoff = before['handoff'] as Map;
    final result = CapturePublicationCodec.decodeResult(
      jsonEncode(handoff['prepareResult']),
    );
    expect(result.state, CapturePreparationState.uncertain);
    expect(result.rawReturnedLocators, hasLength(2));
    expect(result.preparation!.audio, isNotNull);
    expect(result.preparation!.metadata, isNull);
    expect(backend.acknowledgements, 1);
    expect(backend.initializations, 0);
    await h.reopen();
    await h.bootstrap();
    final fresh = OwnerWitnessBackend(h.f.db);
    final recovered = await RecordingPersistence(
      db: h.f.db,
      backend: fresh,
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    expect(recovered.recoveredIds, isEmpty);
    expect(recovered.retainedReservationIds, [r.id]);
    expect((await fresh.journal())['handoff'], handoff);
    expect(fresh.creates, 0);
    expect(fresh.observations, 0);
    expect(fresh.initializations, 0);
    expect(await h.f.audio('A', r.key.dumpId).length(), 0);
    expect(await h.f.metadata('A', r.key.dumpId).length(), 0);
  });
  test(
      'v2 intent replay preserves exact Unicode whitespace and null metadata bytes',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final r = await begin(h);
    final backend = OwnerWitnessBackend(h.f.db);
    await h.f.db.customStatement(
      "CREATE TRIGGER stop_intent BEFORE UPDATE OF publication_json ON capture_reservations WHEN json_extract(NEW.publication_json, '\$.handoff.stage')='preparing' BEGIN SELECT RAISE(ABORT, 'fixture'); END",
    );
    await expectLater(saveWith(h, r, backend), throwsA(isA<SqliteException>()));
    await h.f.db.customStatement('DROP TRIGGER stop_intent');
    final j = await backend.journal();
    final metadata = j['metadata'] as Map<String, dynamic>;
    metadata['title'] = 'café 🧪';
    metadata['transcript'] = null;
    final frozen =
        ' \n${const JsonEncoder.withIndent('  ').convert(metadata)}\n';
    (j['handoff'] as Map)['metadataJson'] = frozen;
    await h.f.db.customStatement(
      'UPDATE capture_reservations SET publication_json=?',
      [jsonEncode(j)],
    );
    await h.reopen();
    await h.bootstrap();
    final result = await RecordingPersistence(
      db: h.f.db,
      backend: OwnerWitnessBackend(h.f.db),
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    expect(result.problems, isEmpty);
    expect(result.recoveredIds, [r.key.dumpId]);
    expect(
      await h.f.metadata('A', r.key.dumpId).readAsBytes(),
      utf8.encode(frozen),
    );
    expect((await h.f.db.getDump(r.key.dumpId))!.title, 'café 🧪');
  });

  test('v2 two fresh recovery owners cannot duplicate complete receipt commit',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final r = await begin(h);
    final writer = OwnerWitnessBackend(h.f.db)..loseResponse = true;
    await expectLater(saveWith(h, r, writer), throwsA(isA<StorageFault>()));
    await h.reopen();
    final owners = List.generate(
      2,
      (_) => DefaultRecordingMutationCoordinator(db: h.f.db),
    );
    final backends = List.generate(2, (_) => OwnerWitnessBackend(h.f.db));
    for (var i = 0; i < 2; i++) {
      await owners[i]
          .restoreFences(unsettled: await backends[i].unsettledUses());
    }
    final results = await Future.wait(
      List.generate(
        2,
        (i) => RecordingPersistence(
          db: h.f.db,
          backend: backends[i],
          mutations: owners[i],
        ).recoverOwnedCaptures(),
      ),
    );
    expect(results.expand((r) => r.recoveredIds), contains(r.key.dumpId));
    expect(await h.f.db.select(h.f.db.dumps).get(), hasLength(1));
    expect(await h.f.db.select(h.f.db.recordingBindings).get(), hasLength(1));
    expect(await h.f.db.select(h.f.db.captureReservations).get(), isEmpty);
    for (var i = 0; i < 2; i++) {
      expect(backends[i].creates, 0);
      expect(backends[i].initializations, 0);
      await backends[i].drain();
      await owners[i].drain();
    }
  });
  test('v2 unresolved complete artifacts cannot bypass owner through import',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final r = await begin(h);
    final backend = OwnerWitnessBackend(h.f.db)..loseResponse = true;
    await expectLater(saveWith(h, r, backend), throwsA(isA<StorageFault>()));
    await h.f.db
        .customStatement("UPDATE capture_reservations SET state='failed'");
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: backend,
      mutations: h.mutations,
    );
    final preview = requireOk(await importer.preview(r.location));
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-unresolved-import', entries: preview.entries),
      ),
    );
    expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
    expect(await h.f.db.select(h.f.db.recordingBindings).get(), isEmpty);
    expect(await h.f.db.hasCaptureJournal(r.key.dumpId), isTrue);
    expect(result, isNotNull);
    expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
  });

  test('v2 preparing before dispatch never blindly creates on recovery',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    final r = await begin(h);
    final backend = OwnerWitnessBackend(h.f.db)..stopBeforePrepare = true;
    await expectLater(saveWith(h, r, backend), throwsA(isA<StorageFault>()));
    expect(((await backend.journal())['handoff'] as Map)['stage'], 'preparing');
    await h.reopen();
    await h.bootstrap();
    final fresh = OwnerWitnessBackend(h.f.db);
    final result = await RecordingPersistence(
      db: h.f.db,
      backend: fresh,
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    expect(result.recoveredIds, isEmpty);
    expect(result.retainedReservationIds, [r.id]);
    expect(result.problems.single.code, ProblemCode.unresolved);
    expect(fresh.creates, 0);
    expect(fresh.observations, 1);
    expect(fresh.initializations, 0);
    expect(await h.f.audio('A', r.key.dumpId).exists(), isFalse);
    expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
  });
  for (final boundary in [
    'empty',
    'audio-complete',
    'audio-partial',
    'metadata-partial',
    'foreign-identical',
    'source-changed',
    'source-missing',
  ]) {
    test('v2 recovery $boundary preserves exact owned or foreign objects',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      final r = await begin(h);
      final backend = OwnerWitnessBackend(h.f.db)..stopBeforeWrite = true;
      await expectLater(saveWith(h, r, backend), throwsA(isA<StorageFault>()));
      final j = await backend.journal();
      final prep = CapturePublicationCodec.decodePreparation(
        jsonEncode((j['handoff'] as Map)['preparation']),
      );
      final audio = h.f.audio('A', r.key.dumpId),
          meta = h.f.metadata('A', r.key.dumpId);
      if (boundary == 'audio-complete' || boundary == 'metadata-partial') {
        await audio.writeAsBytes([1, 2, 3], flush: true);
      }
      if (boundary == 'audio-partial') {
        await audio.writeAsBytes([1], flush: true);
      }
      if (boundary == 'metadata-partial') {
        await meta.writeAsBytes([123], flush: true);
      }
      if (boundary == 'foreign-identical') {
        await audio.rename('${audio.path}.held');
        await audio.writeAsBytes([1, 2, 3], flush: true);
        await meta.writeAsString(prep.metadataJson, flush: true);
      }
      if (boundary == 'source-changed') {
        await File(r.stagingPath).writeAsBytes([9, 8, 7], flush: true);
      }
      if (boundary == 'source-missing') await File(r.stagingPath).delete();
      final beforeAudio = await audio.readAsBytes(),
          beforeMeta = await meta.readAsBytes();
      CaptureObjectIdentity identity(File f) {
        final handle = openCaptureHandle(f.path);
        try {
          return handle.identity;
        } finally {
          handle.close();
        }
      }

      final aid = identity(audio), mid = identity(meta);
      await h.reopen();
      await h.bootstrap();
      final fresh = OwnerWitnessBackend(h.f.db);
      final result = await RecordingPersistence(
        db: h.f.db,
        backend: fresh,
        mutations: h.mutations,
      ).recoverOwnedCaptures();
      final success = boundary == 'empty' || boundary == 'audio-complete';
      expect(result.recoveredIds, success ? [r.key.dumpId] : isEmpty);
      expect(fresh.creates, 0);
      expect(fresh.observations, 0);
      expect(fresh.initializations, success ? 1 : 0);
      expect(identity(audio), aid);
      expect(identity(meta), mid);
      if (success) {
        expect(result.problems, isEmpty);
        expect(await audio.readAsBytes(), [1, 2, 3]);
        expect(await meta.readAsBytes(), utf8.encode(prep.metadataJson));
      } else {
        expect(result.retainedReservationIds, [r.id]);
        expect(result.problems, isNotEmpty);
        if (boundary == 'foreign-identical') {
          expect(result.problems.single.code, ProblemCode.conflict);
        }
        expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
        expect(await audio.readAsBytes(), beforeAudio);
        expect(await meta.readAsBytes(), beforeMeta);
      }
    });
  }

  for (final stage in ['preparing', 'prepared', 'initializing', 'complete']) {
    test('v2 SQL $stage checkpoint fails without losing durable authority',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      final r = await begin(h);
      final backend = OwnerWitnessBackend(h.f.db);
      await h.f.db.customStatement(
          '''CREATE TRIGGER reject_stage BEFORE UPDATE OF publication_json ON capture_reservations
        WHEN json_extract(NEW.publication_json, '\$.handoff.stage') = '$stage'
         AND json_extract(OLD.publication_json, '\$.handoff.stage') != '$stage'
        BEGIN SELECT RAISE(ABORT, 'fixture exact checkpoint'); END''');
      await expectLater(saveWith(h, r, backend), throwsA(isA<Exception>()));
      final j = await backend.journal();
      final saved = j['handoff'] as Map;
      expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
      expect(await File(r.stagingPath).readAsBytes(), [1, 2, 3]);
      if (stage == 'preparing') {
        expect(saved['stage'], 'intent');
        expect(backend.creates, 0);
        expect(await h.f.audio('A', r.key.dumpId).exists(), isFalse);
      } else if (stage == 'prepared') {
        expect(saved['stage'], 'preparing');
        expect(saved['preparation'], isNull);
        expect(backend.acknowledgements, 0);
        expect(backend.initializations, 0);
        expect(await h.f.audio('A', r.key.dumpId).length(), 0);
        expect(await h.f.metadata('A', r.key.dumpId).length(), 0);
      } else {
        expect(saved['preparation'], isNotNull);
        expect(
          saved['stage'],
          stage == 'initializing' ? 'prepared' : 'initializing',
        );
        expect(backend.initializations, stage == 'initializing' ? 0 : 1);
      }
      await h.f.db.customStatement('DROP TRIGGER reject_stage');
      await h.reopen();
      await h.bootstrap();
      final fresh = OwnerWitnessBackend(h.f.db);
      final recovered = await RecordingPersistence(
        db: h.f.db,
        backend: fresh,
        mutations: h.mutations,
      ).recoverOwnedCaptures();
      expect(recovered.problems, isEmpty);
      expect(recovered.recoveredIds, [r.key.dumpId]);
      expect(recovered.retainedReservationIds, isEmpty);
      expect(fresh.creates, stage == 'preparing' ? 1 : 0);
      expect(fresh.observations, stage == 'prepared' ? 1 : 0);
      expect(fresh.initializations, stage == 'complete' ? 0 : 1);
      expect(await h.f.db.select(h.f.db.recordingBindings).get(), hasLength(1));
    });
  }
  for (final lost in ['response', 'ack']) {
    test('v2 lost $lost retains real effects and durable owner ordering',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      final r = await begin(h);
      final backend = OwnerWitnessBackend(h.f.db)
        ..loseResponse = lost == 'response'
        ..loseAcknowledgement = lost == 'ack';
      if (lost == 'response') {
        await expectLater(
          saveWith(h, r, backend),
          throwsA(isA<StorageFault>()),
        );
        final beforeAudio = await h.f.audio('A', r.key.dumpId).readAsBytes();
        final beforeMeta = await h.f.metadata('A', r.key.dumpId).readAsBytes();
        final fresh = OwnerWitnessBackend(h.f.db);
        final recovered = await RecordingPersistence(
          db: h.f.db,
          backend: fresh,
          mutations: h.mutations,
        ).recoverOwnedCaptures();
        expect(recovered.problems, isEmpty);
        expect(recovered.recoveredIds, [r.key.dumpId]);
        expect(fresh.creates, 0);
        expect(fresh.initializations, 0);
        expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), beforeAudio);
        expect(await h.f.metadata('A', r.key.dumpId).readAsBytes(), beforeMeta);
      } else {
        expect((await saveWith(h, r, backend)).id, r.key.dumpId);
      }
      expect(backend.acknowledgements, 1);
      expect(await h.f.db.select(h.f.db.recordingBindings).get(), hasLength(1));
    });
  }
  for (final bad in [
    'extra',
    'version',
    'stage',
    'startedAtMs',
    'mode',
    'key',
    'metadataJson',
    'digest',
    'fractional',
    'v1-null',
  ]) {
    test('v2 strict frozen journal rejects $bad without mutation', () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      final r = await begin(h);
      final backend = OwnerWitnessBackend(h.f.db)..loseResponse = true;
      await expectLater(saveWith(h, r, backend), throwsA(isA<StorageFault>()));
      final j = await backend.journal();
      final handoff = j['handoff'] as Map;
      switch (bad) {
        case 'extra':
          handoff['unexpected'] = true;
        case 'version':
          j['version'] = 99;
        case 'stage':
          handoff['stage'] = 'other';
        case 'startedAtMs':
          handoff['startedAtMs'] = 1;
        case 'mode':
          handoff['mode'] = 'brain_dump';
        case 'key':
          (handoff['key'] as Map)['incarnation'] = 'fixture-foreign';
        case 'metadataJson':
          handoff['metadataJson'] = '{}';
        case 'digest':
          handoff['audioSha256'] = '0' * 64;
        case 'fractional':
          (j['stopped'] as Map)['sizeBytes'] = 3.5;
        case 'v1-null':
          j['version'] = 1;
          j.remove('handoff');
      }
      final raw = ' \n${jsonEncode(j)}\n';
      await h.f.db.customStatement(
        'UPDATE capture_reservations SET publication_json=?',
        [raw],
      );
      final audio = await h.f.audio('A', r.key.dumpId).readAsBytes();
      final meta = await h.f.metadata('A', r.key.dumpId).readAsBytes();
      await h.reopen();
      await h.bootstrap();
      final fresh = OwnerWitnessBackend(h.f.db);
      final recovered = await RecordingPersistence(
        db: h.f.db,
        backend: fresh,
        mutations: h.mutations,
      ).recoverOwnedCaptures();
      expect(recovered.recoveredIds, isEmpty);
      expect(recovered.retainedReservationIds, [r.id]);
      expect(
        recovered.problems.single.code,
        bad == 'v1-null'
            ? ProblemCode.unresolved
            : bad == 'version'
                ? ProblemCode.unsupported
                : ProblemCode.invalid,
      );
      expect(
        (await h.f.db.select(h.f.db.captureReservations).getSingle())
            .publicationJson,
        raw,
      );
      expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
      expect(await h.f.audio('A', r.key.dumpId).readAsBytes(), audio);
      expect(await h.f.metadata('A', r.key.dumpId).readAsBytes(), meta);
      expect(fresh.creates, 0);
      expect(fresh.initializations, 0);
      expect(fresh.acknowledgements, 0);
    });
  }
  for (final mode in ['brain_dump', 'meeting']) {
    test(
        mode == 'brain_dump'
            ? 'real filesystem save persists audio sidecar and valid DB row'
            : 'meeting recordings are private local-only from creation',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await h.bootstrap();
      final reservation = requireOk(await h.catalog.reserveCapture(mode: mode));
      final lease = requireOk(
        await h.mutations.acquire(
          reservation.key.dumpId,
          UseKind.capture,
          expectedIncarnation: reservation.key.incarnation,
        ),
      );
      final staging = File(reservation.stagingPath);
      await staging.writeAsBytes([0x4f, 0x67, 0x67, 0x53, 1], flush: true);
      try {
        final row = await RecordingPersistence(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).save(
          reservation,
          RecordingResult(
            path: staging.path,
            durationSeconds: 3,
            sizeBytes: 5,
          ),
          now: DateTime.utc(2030),
          lease: lease,
        );
        expect(row.title, isNotEmpty);
        expect(row.audioSizeBytes, 5);
        expect(await h.f.audio('A', row.id).readAsBytes(), hasLength(5));
        expect((await h.f.db.getDump(row.id))?.title, row.title);
        final entries = requireOk(
          await settled(h.backend.listRecordingsAt(reservation.location)),
        );
        expect(entries.single.metadata?['title'], row.title);
        expect(row.syncStatus, mode == 'meeting' ? 'local_only' : 'pending');
        expect(entries.single.metadata?['syncStatus'], row.syncStatus);
        expect(await staging.exists(), isFalse);
      } finally {
        await lease.close();
      }
    });
  }
}

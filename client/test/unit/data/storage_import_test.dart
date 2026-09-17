// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_importer.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final schema in [1, 2]) {
    test(
        'SAF channel schema $schema decoding and typed validation preserve peers',
        () async {
      const channel = MethodChannel('fixture/task5-import');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final h = CatalogHarness();
      final backend = SafStorageBackend(channel: channel);
      final location = (
        id: 'fixture-saf-source',
        label: 'Fixture',
        directory: (
          kind: 'saf',
          path: '',
          treeUri: 'content://fixture/tree/root',
          authority: 'fixture',
          documentId: 'root'
        )
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'activeOperations') return [];
        if (call.method == 'listRecordingsAt') {
          return {'operationId': (call.arguments as Map)['operationId']};
        }
        if (call.method == 'acknowledgeOperation') return null;
        return {
          'state': 'settled',
          'result': [
            for (final id in [
              'fixture-valid',
              'fixture-wrong-type',
              'fixture-malformed',
            ])
              {
                'id': id,
                'audio': {
                  'version': 1,
                  'kind': 'saf',
                  'value': 'content://fixture/document/$id',
                },
                'sizeBytes': 3,
                'modifiedAt': 1234,
                'metadataJson': id == 'fixture-malformed'
                    ? '{'
                    : jsonEncode({
                        'schemaVersion': schema,
                        'id': id,
                        'transcript':
                            id == 'fixture-wrong-type' ? 42 : 'Retained words',
                        'transcriptionRequestId': null,
                        'transcriptionError': 'manual_edit:fixture-retained',
                      }),
                'problem': null,
              },
          ],
        };
      });
      addTearDown(() async {
        await backend.drain();
        messenger.setMockMethodCallHandler(channel, null);
        await h.close();
      });
      final importer = BoundRecordingImporter(
        db: h.f.db,
        backend: backend,
        mutations: h.mutations,
      );
      final preview = requireOk(await importer.preview(location));
      expect(preview.entries.first.metadata!['schemaVersion'], schema);
      final result = requireOk(
        await importer.adoptConfirmed(
          (operationId: 'fixture-saf-adopt', entries: preview.entries),
        ),
      );
      expect(
        result.items.map((r) => r.state),
        [ImportState.adopted, ImportState.invalid, ImportState.invalid],
      );
      final row = (await h.f.db.getDump('fixture-valid'))!;
      expect(row.transcript, 'Retained words');
      expect(row.transcriptionRequestId, isNull);
      expect(
        row.transcriptionError,
        schema == 2 ? 'manual_edit:fixture-retained' : null,
      );
      expect(
        (await h.f.db.boundRecording(row.id))!.location.directory,
        location.directory,
      );
    });
  }
  test(
      'import SQLite failure is an unavailable item and does not lose valid peers',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    for (final id in ['fixture-db-fail', 'fixture-peer']) {
      await h.f.audio('A', id).writeAsBytes([1, 2, 3]);
    }
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    final preview = requireOk(
      await importer.preview(fileLocation('A', h.f.directory('A'))),
    );
    await h.f.db.customStatement(
      "CREATE TRIGGER import_abort BEFORE INSERT ON dumps WHEN NEW.id='fixture-db-fail' BEGIN SELECT RAISE(ABORT, 'synthetic import failure'); END",
    );
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-db-import', entries: preview.entries),
      ),
    );
    expect(
      result.items.singleWhere((r) => r.id == 'fixture-db-fail').state,
      ImportState.unavailable,
    );
    expect(
      result.items.singleWhere((r) => r.id == 'fixture-peer').state,
      ImportState.adopted,
    );
    expect(await h.f.db.boundRecording('fixture-db-fail'), isNull);
    expect(await h.f.audio('A', 'fixture-db-fail').readAsBytes(), [1, 2, 3]);
    expect(h.mutations.hasActiveCapture, isFalse);
  });
  test(
      'preview isolates foreign-root entries instead of discarding valid peers',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    await h.f.audio('A', 'fixture-good-peer').writeAsBytes([1]);
    await h.f.audio('B', 'fixture-foreign-peer').writeAsBytes([2]);
    final a = fileLocation('A', h.f.directory('A'));
    final b = fileLocation('B', h.f.directory('B'));
    final valid =
        requireOk(await settled(h.f.backend.listRecordingsAt(a))).single;
    final foreign =
        requireOk(await settled(h.f.backend.listRecordingsAt(b))).single;
    h.backend.listing =
        (_) => ImmediateIo('fixture-mixed-listing', Ok([foreign, valid]));
    final preview = requireOk(
      await BoundRecordingImporter(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
      ).preview(a),
    );
    expect(preview.entries.first.problem?.code, ProblemCode.invalid);
    expect(preview.entries.last.problem, isNull);
  });
  test('retired IDs and owned capture IDs cannot be imported', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.seed('fixture-import-retired', status: 'completed');
    await h.bootstrap();
    final binding = (await h.f.db.boundRecording('fixture-import-retired'))!;
    final ticket = requireOk(
      await h.f.db.claimLocalDeletion(
        'fixture-retire',
        (
          id: binding.key.dumpId,
          binding: binding,
          title: 'Synthetic',
          eligibility: Eligibility.eligible,
          retryTicketId: null
        ),
      ),
    );
    for (final component in RecordingComponent.values) {
      await h.f.db.recordDeletionComponent(
        ticket.id,
        component,
        (state: ComponentState.removed, problem: null),
      );
    }
    await h.f.db.finishLocalDeletion(ticket.id);
    final r = requireOk(await h.catalog.reserveCapture(mode: 'meeting'));
    await h.f.audio('A', r.key.dumpId).writeAsBytes([3, 2, 1]);
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    final result = requireOk(
      await importer.adoptConfirmed(
        (
          operationId: 'fixture-retired-import',
          entries: requireOk(
            await importer.preview(fileLocation('A', h.f.directory('A'))),
          ).entries
        ),
      ),
    );
    expect(
      result.items.singleWhere((i) => i.id == binding.key.dumpId).state,
      ImportState.retired,
    );
    expect(
      result.items.singleWhere((i) => i.id == r.key.dumpId).state,
      ImportState.collision,
    );
    expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
  });
  test(
      'changed audio and simultaneous same-source adoption remain collision safe',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    const id = 'fixture-racing-import';
    await h.f.audio('A', id).writeAsBytes([1]);
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    final old = requireOk(
      await importer.preview(fileLocation('A', h.f.directory('A'))),
    );
    await h.f.audio('A', id).writeAsBytes([2, 3]);
    expect(
      requireOk(
        await importer.adoptConfirmed(
          (operationId: 'fixture-stale-import', entries: old.entries),
        ),
      ).items.single.state,
      ImportState.collision,
    );
    final current = requireOk(
      await importer.preview(fileLocation('A', h.f.directory('A'))),
    );
    final results = await Future.wait([
      for (final operationId in ['fixture-race-one', 'fixture-race-two'])
        importer.adoptConfirmed(
          (operationId: operationId, entries: current.entries),
        ),
    ]);
    expect(
      results.map((r) => requireOk(r).items.single.state),
      unorderedEquals([ImportState.adopted, ImportState.alreadyKnown]),
    );
    expect(await h.f.db.select(h.f.db.dumps).get(), hasLength(1));
  });
  test(
      'typed source-bound adoption preserves schema 1/2 nullable/manual fields and same-source replay',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    for (final schema in [1, 2]) {
      final id = 'fixture-import-schema-$schema';
      await h.f.audio('B', id).writeAsBytes([3, 2, 1]);
      await h.f.metadata('B', id).writeAsString(
            jsonEncode({
              'schemaVersion': schema,
              'id': id,
              'title': 'Retained title',
              'transcript': 'Retained words',
              'meetingNotes': null,
              'transcriptionRequestId': null,
              'transcriptionJobId': null,
              'transcriptionAttempt': 4,
              'transcriptionStatus': 'completed',
              'transcriptionError': schema == 2
                  ? 'sidecar_sync_pending: manual_edit:fixture-revision'
                  : null,
            }),
          );
    }
    final source = fileLocation('legacy-filesystem', h.f.directory('B'));
    final preview = requireOk(await importer.preview(source));
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-adopt', entries: preview.entries),
      ),
    );
    expect(result.items.map((i) => i.state), everyElement(ImportState.adopted));
    final snapshots =
        (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
            .map((r) => r.data)
            .toList();
    final two = (await h.f.db.getDump('fixture-import-schema-2'))!;
    expect(
      two.transcriptionError,
      'sidecar_sync_pending: manual_edit:fixture-revision',
    );
    expect(two.transcriptionRequestId, isNull);
    expect(two.transcriptionJobId, isNull);
    expect(two.meetingNotes, isNull);
    final repeated = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-adopt-again', entries: preview.entries),
      ),
    );
    expect(
      repeated.items.map((i) => i.state),
      everyElement(ImportState.alreadyKnown),
    );
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
          .map((r) => r.data)
          .toList(),
      snapshots,
    );
    final defaultState =
        await h.f.db.select(h.f.db.storageCatalogStates).getSingle();
    expect(
      (await h.catalog.watchDefault().first).location!.directory.path,
      h.f.directory('A'),
    );
    expect(defaultState.revision, 1);
  });
  test(
      'audio-only import requires explicit registered legacy authority and isolates malformed metadata',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    await h.f.audio('B', 'fixture-unowned').writeAsBytes([1]);
    final unowned = requireOk(
      await importer.preview(fileLocation('B', h.f.directory('B'))),
    );
    expect(
      requireOk(
        await importer.adoptConfirmed(
          (operationId: 'fixture-no-audio-only', entries: unowned.entries),
        ),
      ).items.single.state,
      ImportState.invalid,
    );
    for (final id in [
      'fixture-legacy-audio',
      'fixture-malformed',
      'fixture-wrong-type',
    ]) {
      await h.f.audio('A', id).writeAsBytes([1]);
    }
    await h.f.metadata('A', 'fixture-malformed').writeAsString('{');
    await h.f.metadata('A', 'fixture-wrong-type').writeAsString(
          jsonEncode(
            {'schemaVersion': 2, 'id': 'fixture-wrong-type', 'transcript': 7},
          ),
        );
    final preview = requireOk(
      await importer.preview(fileLocation('A', h.f.directory('A'))),
    );
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-legacy-adopt', entries: preview.entries),
      ),
    );
    expect(
      result.items.singleWhere((i) => i.id == 'fixture-legacy-audio').state,
      ImportState.adopted,
    );
    expect(
      result.items
          .where((i) => i.id != 'fixture-legacy-audio')
          .map((i) => i.state),
      everyElement(ImportState.invalid),
    );
  });
  test(
      'disappeared confirmed source is unavailable without importing another root',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    const id = 'fixture-disappeared';
    await h.f.audio('A', id).writeAsBytes([1]);
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    final preview = requireOk(
      await importer.preview(fileLocation('A', h.f.directory('A'))),
    );
    await h.f.audio('A', id).delete();
    await h.f.audio('B', id).writeAsBytes([1]);
    expect(
      requireOk(
        await importer.adoptConfirmed(
          (operationId: 'fixture-disappeared-op', entries: preview.entries),
        ),
      ).items.single.state,
      ImportState.unavailable,
    );
    expect(await h.f.db.getDump(id), isNull);
  });
  test('different-root same ID and mismatched sidecar do not overwrite',
      () async {
    final f = StorageFixture.create();
    final m = DefaultRecordingMutationCoordinator(db: f.db);
    addTearDown(() async {
      await m.drain();
      await f.close();
    });
    final old = await f.seed('fixture-collision');
    await m.restoreFences();
    final before = (await f.db.getDump(old.key.dumpId))!.toJson();
    await f.audio('B', old.key.dumpId).writeAsBytes([9, 8, 7]);
    await f.metadata('B', old.key.dumpId).writeAsString(
          jsonEncode(
            {'schemaVersion': 2, 'id': old.key.dumpId, 'title': 'Foreign'},
          ),
        );
    await f.audio('B', 'fixture-invalid').writeAsBytes([8]);
    await f
        .metadata('B', 'fixture-invalid')
        .writeAsString(jsonEncode({'schemaVersion': 2, 'id': 'different-id'}));
    final importer =
        BoundRecordingImporter(db: f.db, backend: f.backend, mutations: m);
    final preview =
        requireOk(await importer.preview(fileLocation('B', f.directory('B'))));
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-import', entries: preview.entries),
      ),
    );
    expect(
      result.items.any(
        (i) => i.id == old.key.dumpId && i.state == ImportState.collision,
      ),
      isTrue,
    );
    expect(
      result.items.any(
        (i) => i.id == 'fixture-invalid' && i.state == ImportState.invalid,
      ),
      isTrue,
    );
    expect((await f.db.getDump(old.key.dumpId))!.toJson(), before);
    expect(await f.audio('A', old.key.dumpId).readAsBytes(), [1, 2, 3]);
    expect(await f.audio('B', old.key.dumpId).readAsBytes(), [9, 8, 7]);
  });
  test('schema 1 sidecar remains available to typed import validation',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    const id = 'fixture-schema-one';
    await f.audio('A', id).writeAsBytes([1, 2, 3]);
    await f.metadata('A', id).writeAsString(
          jsonEncode(
            {'schemaVersion': 1, 'id': id, 'transcript': 'Original words'},
          ),
        );
    final entries = requireOk(
      await settled(
        f.backend.listRecordingsAt(fileLocation('A', f.directory('A'))),
      ),
    );
    expect(entries.single.problem, isNull);
    expect(entries.single.metadata!['schemaVersion'], 1);
    expect(entries.single.metadata!['transcript'], 'Original words');
  });
  test(
      'durable note pair imports the note row, re-import is idempotent, and '
      'an .opus peer still adopts', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    const noteId = 'fixture-note-pair';
    const body = 'Durable note body words';
    final bytes = utf8.encode(body);
    await File(p.join(h.f.directory('B'), '$noteId.md'))
        .writeAsBytes(bytes, flush: true);
    await h.f.metadata('B', noteId).writeAsString(
          jsonEncode({
            'schemaVersion': 2,
            'id': noteId,
            'createdAt': '2030-01-02T03:04:05.000Z',
            'updatedAt': '2030-01-02T03:04:05.000Z',
            'mode': 'text_note',
            'durationSeconds': 0,
            'title': 'Retained note title',
            'transcript': body,
            'transcriptionStatus': 'not_applicable',
            'audioSizeBytes': bytes.length,
            'syncStatus': 'pending',
          }),
          flush: true,
        );
    const peerId = 'fixture-note-audio-peer';
    await h.f.audio('B', peerId).writeAsBytes([1, 2, 3]);
    await h.f.metadata('B', peerId).writeAsString(
          jsonEncode({
            'schemaVersion': 2,
            'id': peerId,
            'mode': 'brain_dump',
            'transcript': 'Peer words',
            'transcriptionStatus': 'completed',
          }),
        );
    final source = fileLocation('B', h.f.directory('B'));
    final preview = requireOk(await importer.preview(source));
    expect(preview.entries.map((e) => e.problem), everyElement(isNull));
    expect(preview.entries.map((e) => e.id).toSet(), {noteId, peerId});
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-note-adopt', entries: preview.entries),
      ),
    );
    expect(result.items.map((i) => i.state), everyElement(ImportState.adopted));
    final row = (await h.f.db.getDump(noteId))!;
    expect(row.mode, 'text_note');
    expect(row.transcript, body, reason: 'note body restores from sidecar');
    expect(row.transcriptionStatus, 'not_applicable');
    expect(row.durationSeconds, 0);
    expect(row.title, 'Retained note title');
    expect(p.basename(row.audioPath), '$noteId.md');
    expect(row.audioSizeBytes, bytes.length);
    expect(
      row.syncStatus,
      'pending',
      reason: 'a recovered note is never marked synced without proof',
    );
    final peer = (await h.f.db.getDump(peerId))!;
    expect(peer.mode, 'brain_dump');
    expect(p.basename(peer.audioPath), '$peerId.opus');
    final snapshots =
        (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
            .map((r) => r.data)
            .toList();
    final repeated = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-note-adopt-again', entries: preview.entries),
      ),
    );
    expect(
      repeated.items.map((i) => i.state),
      everyElement(ImportState.alreadyKnown),
    );
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
          .map((r) => r.data)
          .toList(),
      snapshots,
      reason: 're-import must not duplicate or mutate rows',
    );
  });
  test(
      'sidecar without its .md is flagged as a missing component and the '
      'adopted row is preserved', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    const noteId = 'fixture-note-orphan';
    const body = 'Orphaned note body';
    final md = File(p.join(h.f.directory('B'), '$noteId.md'));
    await md.writeAsBytes(utf8.encode(body), flush: true);
    await h.f.metadata('B', noteId).writeAsString(
          jsonEncode({
            'schemaVersion': 2,
            'id': noteId,
            'mode': 'text_note',
            'title': 'Orphaned note',
            'transcript': body,
            'transcriptionStatus': 'not_applicable',
            'durationSeconds': 0,
          }),
        );
    final source = fileLocation('B', h.f.directory('B'));
    final preview = requireOk(await importer.preview(source));
    expect(
      requireOk(
        await importer.adoptConfirmed(
          (operationId: 'fixture-orphan-adopt', entries: preview.entries),
        ),
      ).items.single.state,
      ImportState.adopted,
    );
    final before = (await h.f.db.getDump(noteId))!.toJson();
    await md.delete();
    final after = requireOk(await importer.preview(source));
    expect(
      after.entries.where((e) => e.id == noteId),
      isEmpty,
      reason: 'an orphan sidecar has no importable content component',
    );
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-orphan-retry', entries: preview.entries),
      ),
    );
    final item = result.items.singleWhere((i) => i.id == noteId);
    expect(item.state, ImportState.unavailable);
    expect(item.problem?.code, ProblemCode.unavailable);
    expect(
      (await h.f.db.getDump(noteId))!.toJson(),
      before,
      reason: 'the missing .md must not damage the already-adopted row',
    );
  });
  test(
      'degraded note sidecar restores a Note title and not_applicable status',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    const noteId = 'fixture-note-degraded';
    const body = 'Degraded note body';
    final createdAt = DateTime.utc(2030, 5, 6, 7, 8, 9);
    await File(p.join(h.f.directory('B'), '$noteId.md'))
        .writeAsBytes(utf8.encode(body), flush: true);
    await h.f.metadata('B', noteId).writeAsString(
          jsonEncode({
            'schemaVersion': 2,
            'id': noteId,
            'mode': 'text_note',
            'transcript': body,
            'createdAt': createdAt.toIso8601String(),
          }),
        );
    final preview = requireOk(
      await importer.preview(fileLocation('B', h.f.directory('B'))),
    );
    expect(
      requireOk(
        await importer.adoptConfirmed(
          (operationId: 'fixture-degraded-adopt', entries: preview.entries),
        ),
      ).items.single.state,
      ImportState.adopted,
    );
    final row = (await h.f.db.getDump(noteId))!;
    expect(row.mode, 'text_note');
    expect(row.transcript, body);
    expect(
      row.title,
      generatedNoteTitle(createdAt),
      reason: 'an untitled note falls back to the Note title, not Recording',
    );
    expect(
      row.transcriptionStatus,
      'not_applicable',
      reason: 'a note must never resurrect a transcribable status',
    );
    expect(row.durationSeconds, 0);
  });
  test('SAF note durable pair adopts the text_note row from channel entries',
      () async {
    const channel = MethodChannel('fixture/task11-saf-note');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final h = CatalogHarness();
    final backend = SafStorageBackend(channel: channel);
    final location = (
      id: 'fixture-saf-note-source',
      label: 'Fixture',
      directory: (
        kind: 'saf',
        path: '',
        treeUri: 'content://fixture/tree/root',
        authority: 'fixture',
        documentId: 'root'
      )
    );
    const noteId = 'fixture-saf-note';
    const body = 'Saf note body';
    final bytes = utf8.encode(body);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'activeOperations') return [];
      if (call.method == 'listRecordingsAt') {
        return {'operationId': (call.arguments as Map)['operationId']};
      }
      if (call.method == 'acknowledgeOperation') return null;
      return {
        'state': 'settled',
        'result': [
          {
            'id': noteId,
            'audio': {
              'version': 1,
              'kind': 'saf',
              'value': 'content://fixture/document/$noteId',
            },
            'sizeBytes': bytes.length,
            'modifiedAt': 1234,
            'metadataJson': jsonEncode({
              'schemaVersion': 2,
              'id': noteId,
              'mode': 'text_note',
              'title': 'Retained note',
              'transcript': body,
              'transcriptionStatus': 'not_applicable',
              'durationSeconds': 0,
              'audioSizeBytes': bytes.length,
            }),
            'problem': null,
          },
        ],
      };
    });
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
      await h.close();
    });
    final importer = BoundRecordingImporter(
      db: h.f.db,
      backend: backend,
      mutations: h.mutations,
    );
    final preview = requireOk(await importer.preview(location));
    expect(preview.entries.single.problem, isNull);
    expect(preview.entries.single.metadata!['mode'], 'text_note');
    final result = requireOk(
      await importer.adoptConfirmed(
        (operationId: 'fixture-saf-note-adopt', entries: preview.entries),
      ),
    );
    expect(result.items.single.state, ImportState.adopted);
    final row = (await h.f.db.getDump(noteId))!;
    expect(row.mode, 'text_note');
    expect(row.transcript, body);
    expect(row.transcriptionStatus, 'not_applicable');
    expect(row.durationSeconds, 0);
    expect(row.title, 'Retained note');
    expect(row.audioSizeBytes, bytes.length);
  });
}

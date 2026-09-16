// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:tangent/data/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_catalog.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import '../../support/storage_fixture.dart';
import '../../support/scripted_storage_backend.dart';

StorageLocation safLocation(String root) => (
      id: 'fixture-saf',
      label: root,
      directory: (
        kind: 'saf',
        path: '',
        authority: 'Fixture.Provider',
        treeUri: 'content://Fixture.Provider/tree/opaque%2Fparent',
        documentId: root
      )
    );
ImportedEntry entry(
  StorageLocation location,
  String id,
  String audio, {
  StorageProblem? problem,
}) =>
    (
      id: id,
      source: location,
      audio: (kind: 'saf', value: audio),
      sizeBytes: 3,
      modifiedAt: DateTime.utc(2030),
      metadata: null,
      problem: problem
    );
Future<void> unbind(CatalogHarness h, String id, {String? audio}) async {
  await h.f.seed(id, status: 'completed');
  await h.f.db
      .customStatement('DELETE FROM recording_bindings WHERE dump_id=?', [id]);
  if (audio != null) {
    await h.f.db.customStatement(
      'UPDATE dumps SET audio_path=? WHERE id=?',
      [audio, id],
    );
  }
}

class UncertainDb extends LocalDb {
  UncertainDb(super.executor) : super.forTesting();
  bool freezeAckLost = false;
  bool defaultAckLost = false;
  @override
  Future<void> freezeLegacyAnchor(String anchorJson) async {
    await super.freezeLegacyAnchor(anchorJson);
    if (freezeAckLost) {
      freezeAckLost = false;
      throw SqliteException(10, 'synthetic lost acknowledgement');
    }
  }

  @override
  Future<T> commitStorageCatalog<T>(Future<T> Function() action) async {
    final result = await super.commitStorageCatalog(action);
    if (defaultAckLost) {
      defaultAckLost = false;
      throw SqliteException(10, 'synthetic lost acknowledgement');
    }
    return result;
  }
}

void main() {
  test(
      'bootstrap is byte-read-only, isolates malformed metadata and unsupported IDs, and cannot bind a foreign same-name file',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await unbind(h, 'fixture-healthy');
    await unbind(h, 'fixture-bad-meta');
    await unbind(h, 'fixture-unsafe');
    await h.f.db.customStatement(
      "UPDATE dumps SET id='fixture-unsafe/child' WHERE id='fixture-unsafe'",
    );
    await h.f.seed('fixture-other-root', folder: 'B');
    await h.f.db.customStatement(
      "DELETE FROM recording_bindings WHERE dump_id='fixture-other-root'",
    );
    await h.f.audio('A', 'fixture-other-root').writeAsBytes([7]);
    await h.f.metadata('A', 'fixture-bad-meta').writeAsString('{invalid');
    final beforeRows =
        (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
            .map((r) => r.data)
            .toList();
    Future<Map<String, List<int>>> files() async {
      final result = <String, List<int>>{};
      for (final folder in ['A', 'B', 'stage']) {
        for (final file
            in await Directory(h.f.directory(folder)).list().toList()) {
          if (file is File) result[file.path] = await file.readAsBytes();
        }
      }
      return result;
    }

    final beforeFiles = await files();
    final result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
    );
    expect(
      result.unresolvedIds.toSet(),
      {'fixture-bad-meta', 'fixture-unsafe/child', 'fixture-other-root'},
    );
    expect(await h.f.db.boundRecording('fixture-healthy'), isNotNull);
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
          .map((r) => r.data)
          .toList(),
      beforeRows,
    );
    expect(await files(), beforeFiles);
    expect(h.backend.componentCalls, 0);
  });
  for (final raw in ['', 'relative/source']) {
    test(
        'unusable file source is frozen literally without creating or substituting directories: $raw',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await unbind(h, 'fixture-raw');
      final result = requireOk(
        await h.catalog.bootstrapLegacyBindings(filesystemLegacyDirectory: raw),
      );
      expect(result.unresolvedIds, ['fixture-raw']);
      final anchor = StorageCodec.encodeLegacyFileAnchor(raw);
      expect(
        (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
            .legacyAnchorJson,
        anchor,
      );
      requireOk(
        await h.catalog.bootstrapLegacyBindings(
          filesystemLegacyDirectory: h.f.directory('B'),
        ),
      );
      expect(
        (await h.f.db.select(h.f.db.recordingBindings).getSingle())
            .legacyAnchorJson,
        anchor,
      );
      expect(await h.f.db.boundRecording('fixture-raw'), isNull);
      expect(h.backend.captureCalls, 1);
    });
  }
  test(
      'malformed resolution protocol retains anchors and unresolved rows without recapture',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await unbind(h, 'fixture-protocol');
    final anchor = StorageCodec.encodeLegacyFileAnchor(h.f.directory('A'));
    h.backend.legacy = (_, frozen) async => frozen == null
        ? Ok((location: null, anchorJson: anchor))
        : const Ok(null);
    var result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
    );
    expect(result.problems.single.code, ProblemCode.invalid);
    h.backend.legacy = (_, frozen) async => Ok(
          (
            location: fileLocation('B', h.f.directory('B')),
            anchorJson: '$frozen '
          ),
        );
    result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    expect(result.problems.single.code, ProblemCode.invalid);
    expect(result.unresolvedIds, ['fixture-protocol']);
    expect(
      (await h.f.db.select(h.f.db.recordingBindings).getSingle())
          .legacyAnchorJson,
      anchor,
    );
    expect(h.backend.captureCalls, 1);
  });

  test(
      'per-row original audio JSON whitespace is retained while ownership recovers',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.seed('fixture-json-bytes');
    final prior = await h.f.db.select(h.f.db.recordingBindings).getSingle();
    final raw = '  ${prior.audioJson}\n';
    await h.f.db.customStatement(
      'UPDATE recording_bindings SET resolved=0, location_id=NULL, audio_json=?, legacy_anchor_json=?',
      [raw, StorageCodec.encodeLegacyFileAnchor(h.f.directory('A'))],
    );
    final result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
    );
    expect(result.unresolvedIds, isEmpty);
    expect(
      (await h.f.db.select(h.f.db.recordingBindings).getSingle()).audioJson,
      raw,
    );
  });

  test(
      'SAF original document identity accepts equivalent spelling but rejects same-name foreign IDs',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    const id = 'fixture-opaque';
    const audio =
        'content://Fixture.Provider/tree/opaque%2fparent/document/audio%2fid%25';
    await unbind(h, id, audio: audio);
    await unbind(
      h,
      'fixture-foreign',
      audio: 'content://Fixture.Provider/document/original',
    );
    final location = safLocation('effective/Tangent');
    final anchor =
        '  ${StorageCodec.encodeLegacySafAnchor(location.directory.treeUri)}\n';
    h.backend.legacy = (_, frozen) async => Ok(
          (
            location: frozen == null ? null : location,
            anchorJson: frozen ?? anchor
          ),
        );
    h.backend.listing = (l) => ImmediateIo(
          'list',
          Ok([
            entry(l, id, 'content://Fixture.Provider/document/audio%2Fid%25'),
            entry(
              l,
              'fixture-foreign',
              'content://Fixture.Provider/document/other',
            ),
          ]),
        );
    final result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    expect(result.unresolvedIds, ['fixture-foreign']);
    final bound = requireOk(await h.catalog.resolveRecording(id));
    expect(bound.audio.value, audio);
    final rows = await h.f.db.select(h.f.db.recordingBindings).get();
    expect(rows.every((b) => b.legacyAnchorJson == anchor), true);
    expect(
      (await h.mutations.acquire('fixture-foreign', UseKind.deletion) as Fail)
          .problem
          .code,
      ProblemCode.unresolved,
    );
  });

  for (final initial in [
    'denied grant',
    'ambiguous child',
    'loading provider',
  ]) {
    test(
        '$initial keeps anchors through actual restart, changed preference/default and recovery',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      const id = 'fixture-return';
      const audio =
          'content://Fixture.Provider/tree/parent/document/audio%2Freturn';
      await unbind(h, id, audio: audio);
      final before =
          (await h.f.db.customSelect('SELECT * FROM dumps').getSingle()).data;
      final root = safLocation(
        initial == 'ambiguous child' ? 'Tangent/direct' : 'Documents/Tangent',
      );
      final anchor = StorageCodec.encodeLegacySafAnchor(root.directory.treeUri);
      var current = anchor;
      var accessible = false;
      h.backend.legacy = (_, frozen) async => Ok(
            (
              location: frozen != null && accessible ? root : null,
              anchorJson: frozen ?? current
            ),
          );
      h.backend.listing = (l) => ImmediateIo('list', Ok([entry(l, id, audio)]));
      final initialResult = requireOk(
        await h.catalog.bootstrapLegacyBindings(
          filesystemLegacyDirectory: h.f.directory('A'),
        ),
      );
      expect(initialResult.unresolvedIds, [id]);
      expect(initialResult.problems.first.code, ProblemCode.unresolved);
      final frozenRow =
          await h.f.db.select(h.f.db.recordingBindings).getSingle();
      expect(
        (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
            .bootstrapVersion,
        1,
      );
      final candidate = await h.choose('B');
      final committed = requireOk(
        await h.catalog.commitDefault(candidate, expectedRevision: 0),
      );
      current =
          StorageCodec.encodeLegacySafAnchor('content://Other.Provider/tree/B');
      await h.reopen();
      accessible = true;
      final recovered = requireOk(
        await h.catalog.bootstrapLegacyBindings(
          filesystemLegacyDirectory: h.f.directory('B'),
        ),
      );
      expect(recovered.unresolvedIds, isEmpty);
      final after = await h.f.db.select(h.f.db.recordingBindings).getSingle();
      expect(after.audioJson, frozenRow.audioJson);
      expect(after.incarnation, frozenRow.incarnation);
      expect(after.legacyAnchorJson, frozenRow.legacyAnchorJson);
      expect(
        (await h.catalog.watchDefault().first).location,
        committed.location,
      );
      expect(
        (await h.catalog.watchDefault().first).revision,
        committed.revision,
      );
      expect(
        (await h.f.db.customSelect('SELECT * FROM dumps').getSingle()).data,
        before,
      );
      expect(h.backend.captureCalls, 1);
      expect(h.backend.resolutionInputs.every((a) => a == anchor), true);
    });
  }
  test('confirmed unconfigured source stays null anchored after a new default',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await unbind(h, 'fixture-unconfigured');
    var configured = false;
    h.backend.legacy = (_, frozen) async => frozen == null
        ? (configured
            ? Ok(
                (
                  location: null,
                  anchorJson:
                      StorageCodec.encodeLegacyFileAnchor(h.f.directory('B'))
                ),
              )
            : const Ok(null))
        : Ok((location: null, anchorJson: frozen));
    await h.bootstrap();
    final anchor = StorageCodec.encodeLegacySafAnchor(null);
    expect(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .legacyAnchorJson,
      anchor,
    );
    configured = true;
    requireOk(
      await h.catalog.commitDefault(await h.choose('B'), expectedRevision: 0),
    );
    await h.reopen();
    await h.bootstrap();
    expect(
      (await h.f.db.select(h.f.db.recordingBindings).getSingle())
          .legacyAnchorJson,
      anchor,
    );
    expect(await h.f.db.boundRecording('fixture-unconfigured'), isNull);
    expect(h.backend.captureCalls, 1);
  });
  for (final code in [
    ProblemCode.invalid,
    ProblemCode.unavailable,
    ProblemCode.denied,
    ProblemCode.io,
  ]) {
    test(
        'unknown capture $code never freezes absent source or advances bootstrap',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await unbind(h, 'fixture-unknown');
      h.backend.legacy = (_, __) async =>
          Fail((code: code, message: 'synthetic capture failure'));
      expect(
        await h.catalog.bootstrapLegacyBindings(
          filesystemLegacyDirectory: h.f.directory('A'),
        ),
        isA<Fail<BootstrapResult>>(),
      );
      final state =
          await h.f.db.select(h.f.db.storageCatalogStates).getSingle();
      expect(state.legacyAnchorJson, isNull);
      expect(state.bootstrapVersion, 0);
      expect(await h.f.db.select(h.f.db.recordingBindings).get(), isEmpty);
      expect(h.backend.resolutionInputs, isEmpty);
    });
  }
  test(
      'gated resolution starts only after durable freeze; restart uses saved bytes',
      () async {
    final h = CatalogHarness();
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await h.close();
    });
    await unbind(h, 'fixture-gated');
    final anchor = StorageCodec.encodeLegacyFileAnchor(h.f.directory('A'));
    h.backend.legacy = (_, frozen) async {
      if (frozen == null) return Ok((location: null, anchorJson: anchor));
      entered.complete();
      await release.future;
      return Ok((location: null, anchorJson: frozen));
    };
    final work = h.catalog
        .bootstrapLegacyBindings(filesystemLegacyDirectory: h.f.directory('A'));
    await entered.future;
    expect(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .legacyAnchorJson,
      anchor,
    );
    release.complete();
    requireOk(await work);
    await h.reopen();
    h.backend.legacy = null;
    requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    expect(
      (await h.f.db.boundRecording('fixture-gated'))!.location.directory.path,
      h.f.directory('A'),
    );
    expect(h.backend.captureCalls, 1);
  });

  test('competing first captures use the SQLite winner, never delayed loser',
      () async {
    final h = CatalogHarness();
    final entered = Completer<void>();
    final release = Completer<void>();
    final otherBackend = ScriptedStorageBackend();
    final otherMutations = DefaultRecordingMutationCoordinator(db: h.f.db);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await otherBackend.drain();
      await otherMutations.drain();
      await h.close();
    });
    final a = StorageCodec.encodeLegacyFileAnchor(h.f.directory('A'));
    final b = StorageCodec.encodeLegacyFileAnchor(h.f.directory('B'));
    h.backend.legacy = (_, frozen) async {
      if (frozen == null) {
        entered.complete();
        await release.future;
        return Ok((location: null, anchorJson: a));
      }
      expect(frozen, b);
      return Ok(
        (location: fileLocation('B', h.f.directory('B')), anchorJson: frozen),
      );
    };
    final first = h.catalog
        .bootstrapLegacyBindings(filesystemLegacyDirectory: h.f.directory('A'));
    await entered.future;
    final other = SqliteStorageCatalog(
      db: h.f.db,
      backend: otherBackend,
      mutations: otherMutations,
      stagingDirectory: h.f.directory('stage'),
      idFactory: () => 'fixture-other',
      now: () => DateTime.utc(2030),
      canChooseDefault: true,
    );
    requireOk(
      await other.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    release.complete();
    requireOk(await first);
    expect(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .legacyAnchorJson,
      b,
    );
    expect(h.backend.resolutionInputs, [b]);
  });
  test(
      'failed freeze does not resolve; restart captures only after successful transaction',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await unbind(h, 'fixture-freeze-failure');
    await h.f.db.customStatement(
      "CREATE TRIGGER reject_freeze BEFORE UPDATE OF legacy_anchor_json ON storage_catalog_state BEGIN SELECT RAISE(ABORT, 'synthetic freeze failure'); END",
    );
    expect(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
      isA<Fail<BootstrapResult>>(),
    );
    expect(h.backend.resolutionInputs, isEmpty);
    expect(
      (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
          .legacyAnchorJson,
      isNull,
    );
    await h.reopen();
    await h.f.db.customStatement('DROP TRIGGER reject_freeze');
    await h.bootstrap();
    expect(h.backend.captureCalls, 2);
    expect(await h.f.db.boundRecording('fixture-freeze-failure'), isNotNull);
  });
  test(
      'lost freeze and default acknowledgements reread committed SQLite authority',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.db.close();
    final db =
        UncertainDb(NativeDatabase(File('${h.f.root.path}/fixture.sqlite')))
          ..freezeAckLost = true;
    h.f.db = db;
    h.resetOwners();
    await h.bootstrap();
    expect(h.backend.captureCalls, 1);
    expect(h.backend.resolutionInputs, hasLength(1));
    final state = await h.catalog.watchDefault().first;
    final candidate = await h.choose('B');
    db.defaultAckLost = true;
    final committed = requireOk(
      await h.catalog
          .commitDefault(candidate, expectedRevision: state.revision),
    );
    expect(committed.location!.directory.path, h.f.directory('B'));
    expect(committed.revision, state.revision + 1);
    await h.reopen();
    expect((await h.catalog.watchDefault().first).location, committed.location);
    expect((await h.catalog.watchDefault().first).revision, committed.revision);
  });
  test(
      'restart after committed freeze and partially frozen chunks preserves keys and all columns',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    for (var i = 0; i < 70; i++) {
      await unbind(h, 'fixture-chunk-${i.toString().padLeft(3, '0')}');
    }
    final before =
        (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
            .map((r) => r.data)
            .toList();
    await h.f.db.customStatement(
      "CREATE TRIGGER fail_chunk BEFORE INSERT ON recording_bindings WHEN NEW.dump_id='fixture-chunk-064' BEGIN SELECT RAISE(ABORT, 'synthetic chunk failure'); END",
    );
    expect(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
      isA<Fail<BootstrapResult>>(),
    );
    final first = await h.f.db.select(h.f.db.recordingBindings).get();
    expect(first, hasLength(64));
    final state = await h.f.db.select(h.f.db.storageCatalogStates).getSingle();
    expect(state.bootstrapVersion, 0);
    expect(state.legacyAnchorJson, isNotNull);
    await h.reopen();
    await h.f.db.customStatement('DROP TRIGGER fail_chunk');
    final result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    expect(result.unresolvedIds, isEmpty);
    final all = await h.f.db.select(h.f.db.recordingBindings).get();
    expect(all, hasLength(70));
    for (final old in first) {
      final row = all.singleWhere((b) => b.dumpId == old.dumpId);
      expect(row.incarnation, old.incarnation);
      expect(row.audioJson, old.audioJson);
      expect(row.legacyAnchorJson, old.legacyAnchorJson);
    }
    expect(
      (await h.f.db.customSelect('SELECT * FROM dumps ORDER BY id').get())
          .map((r) => r.data)
          .toList(),
      before,
    );
    expect(h.backend.captureCalls, 1);
  });
  test(
      'reopen after freeze before first row chunk retains unavailable file A, not later B',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await unbind(h, 'fixture-missing');
    await h.f.db.customStatement(
      "CREATE TRIGGER fail_rows BEFORE INSERT ON recording_bindings BEGIN SELECT RAISE(ABORT, 'synthetic first chunk failure'); END",
    );
    expect(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
      isA<Fail<BootstrapResult>>(),
    );
    expect(await h.f.db.select(h.f.db.recordingBindings).get(), isEmpty);
    final moved =
        await Directory(h.f.directory('A')).rename(h.f.directory('A-away'));
    await h.reopen();
    await h.f.db.customStatement('DROP TRIGGER fail_rows');
    var result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    expect(result.unresolvedIds, ['fixture-missing']);
    expect(await Directory(h.f.directory('A')).exists(), false);
    await moved.rename(h.f.directory('A'));
    result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('B'),
      ),
    );
    expect(result.unresolvedIds, isEmpty);
    expect(
      (await h.f.db.boundRecording('fixture-missing'))!.location.directory.path,
      h.f.directory('A'),
    );
    expect(h.backend.captureCalls, 1);
  });
  test(
      'per-row frozen source overrides singleton and recovery never adopts unrelated files',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await unbind(h, 'fixture-row-a');
    await h.f.seed('fixture-row-b', folder: 'B');
    await h.f.db.customStatement(
      "UPDATE recording_bindings SET resolved=0, location_id=NULL, legacy_anchor_json=? WHERE dump_id='fixture-row-b'",
      [StorageCodec.encodeLegacyFileAnchor(h.f.directory('B'))],
    );
    await h.f.audio('A', 'fixture-not-in-db').writeAsBytes([8]);
    final result = requireOk(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
    );
    expect(result.unresolvedIds, isEmpty);
    expect(
      (await h.f.db.boundRecording('fixture-row-b'))!.location.directory.path,
      h.f.directory('B'),
    );
    expect(await h.f.db.getDump('fixture-not-in-db'), isNull);
    expect(await h.f.metadata('A', 'fixture-not-in-db').exists(), false);
  });
  for (final value in ['{}', '{"version":2}', '{"kind":"file"}', 'garbage']) {
    test('persisted malformed envelope $value fails closed without recapture',
        () async {
      final h = CatalogHarness();
      addTearDown(h.close);
      await h.f.db.customStatement(
        'UPDATE storage_catalog_state SET legacy_anchor_json=?',
        [value],
      );
      expect(
        await h.catalog.bootstrapLegacyBindings(
          filesystemLegacyDirectory: h.f.directory('A'),
        ),
        isA<Fail<BootstrapResult>>(),
      );
      expect(h.backend.captureCalls, 0);
      expect(h.backend.resolutionInputs, isEmpty);
      expect(
        (await h.f.db.select(h.f.db.storageCatalogStates).getSingle())
            .legacyAnchorJson,
        value,
      );
    });
  }
  test(
      'completed bootstrap with SQL NULL is inconsistent, not permission to recapture',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.f.db.customStatement(
      'UPDATE storage_catalog_state SET bootstrap_version=1',
    );
    expect(
      await h.catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: h.f.directory('A'),
      ),
      isA<Fail<BootstrapResult>>(),
    );
    expect(h.backend.captureCalls, 0);
  });
  test(
      'duplicate entries, incomplete enumeration and metadata failure stay unresolved',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    const id = 'fixture-duplicate';
    const audio = 'content://Fixture.Provider/document/dup';
    await unbind(h, id, audio: audio);
    final root = safLocation('root');
    final anchor = StorageCodec.encodeLegacySafAnchor(root.directory.treeUri);
    h.backend.legacy = (_, frozen) async => Ok(
          (
            location: frozen == null ? null : root,
            anchorJson: frozen ?? anchor
          ),
        );
    h.backend.listing = (l) =>
        ImmediateIo('list', Ok([entry(l, id, audio), entry(l, id, audio)]));
    await h.bootstrap();
    expect(await h.f.db.boundRecording(id), isNull);
    h.backend.listing = (_) => ImmediateIo(
          'list',
          const Fail(
            (code: ProblemCode.unavailable, message: 'incomplete snapshot'),
          ),
        );
    await h.bootstrap();
    expect(await h.f.db.boundRecording(id), isNull);
    h.backend.listing = (l) => ImmediateIo(
          'list',
          Ok([
            entry(
              l,
              id,
              audio,
              problem: (code: ProblemCode.invalid, message: 'bad metadata'),
            ),
          ]),
        );
    await h.bootstrap();
    expect(await h.f.db.boundRecording(id), isNull);
    h.backend.listing = (l) => ImmediateIo('list', Ok([entry(l, id, audio)]));
    await h.bootstrap();
    expect(await h.f.db.boundRecording(id), isNotNull);
  });
  test(
      'freeze exact source before resolution and account original rows without rewriting Dumps',
      () async {
    final f = StorageFixture.create();
    final backend = ScriptedStorageBackend();
    final mutations = DefaultRecordingMutationCoordinator(db: f.db);
    addTearDown(() async {
      await backend.drain();
      await mutations.drain();
      await f.close();
    });
    await f.seed('fixture-legacy', status: 'completed');
    await f.db.customStatement('DELETE FROM recording_bindings');
    final before = (await f.db.customSelect('SELECT * FROM dumps').get())
        .map((r) => r.data)
        .toList();
    final anchor = StorageCodec.encodeLegacyFileAnchor(f.directory('A'));
    backend.legacy = (path, frozen) async {
      if (frozen == null) return Ok((location: null, anchorJson: anchor));
      expect(
        (await f.db.select(f.db.storageCatalogStates).getSingle())
            .legacyAnchorJson,
        anchor,
      );
      expect(frozen, anchor);
      return Ok(
        (location: fileLocation('A', f.directory('A')), anchorJson: frozen),
      );
    };
    var n = 0;
    final catalog = SqliteStorageCatalog(
      db: f.db,
      backend: backend,
      mutations: mutations,
      stagingDirectory: f.directory('stage'),
      idFactory: () => 'fixture-key-${n++}',
      now: () => DateTime.utc(2030),
      canChooseDefault: true,
    );
    final result = requireOk(
      await catalog.bootstrapLegacyBindings(
        filesystemLegacyDirectory: f.directory('A'),
      ),
    );
    expect(
      (await f.db.select(f.db.storageCatalogStates).getSingle())
          .legacyAnchorJson,
      anchor,
    );
    expect(result.unresolvedIds, isEmpty);
    expect(
      (await f.db.boundRecording('fixture-legacy'))!.audio.value,
      f.audio('A', 'fixture-legacy').path,
    );
    expect(
      (await f.db.customSelect('SELECT * FROM dumps').get())
          .map((r) => r.data)
          .toList(),
      before,
    );
    expect(backend.captureCalls, 1);
    expect(backend.resolutionInputs, [anchor]);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/capture_publication_codec.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';
import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';

/// Task 3: mode-aware content extension. A text_note reservation stages and
/// publishes `<id>.md` in the audio component slot; every audio mode still
/// STRICTLY requires `<id>.opus`. All expected basenames derive from the ONE
/// shared helper `contentExtensionForMode` — identity/ownership checks keep
/// full strength, only the expected extension varies by mode.
void main() {
  test('contentExtensionForMode maps text_note to md, audio modes to opus',
      () {
    expect(contentExtensionForMode('text_note'), 'md');
    expect(contentExtensionForMode('brain_dump'), 'opus');
    expect(contentExtensionForMode('meeting'), 'opus');
  });

  test('reserveCapture(mode: text_note) stages <id>.md', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'text_note'));
    expect(r.mode, 'text_note');
    expect(p.basename(r.stagingPath), '${r.id}.md');
    expect(p.dirname(r.stagingPath), h.f.directory('stage'));
  });

  test(
      'text_note prepare→publish→commit lands <id>.md + sidecar and the '
      'binding audio component basename is <id>.md', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'text_note'));
    final noteBytes = utf8.encode('# Note\nstaged text note body 🧪');
    await File(r.stagingPath).writeAsBytes(noteBytes, flush: true);
    final metadata = jsonEncode({
      'schemaVersion': 2,
      'id': r.key.dumpId,
      'mode': 'text_note',
      'title': 'Note fixture',
      'transcript': 'staged text note body 🧪',
      'transcriptionStatus': 'not_applicable',
    });
    final digest = sha256.convert(noteBytes).toString();
    addTearDown(() async {
      await h.backend.drain();
      await h.backend.acknowledgeCapturePreparation('capture-${r.id}-prepare');
    });
    final prepared = await settled(
      h.backend.prepareCapture(
        r,
        metadata,
        digest,
        'capture-${r.id}-prepare',
        observeOnly: false,
      ),
    );
    expect(prepared.state, CapturePreparationState.prepared,
        reason: '${prepared.problem}',);
    expect(prepared.preparation!.audio!.name, '${r.key.dumpId}.md');
    expect(
      prepared.preparation!.metadata!.name,
      '${r.key.dumpId}.meta.json',
    );
    final published = requireOk(
      await settled(
        h.backend.publishPreparedCapture(r, prepared.preparation!),
      ),
    );
    final binding = published.binding;
    expect(p.basename(binding.audio.value), '${r.key.dumpId}.md');
    expect(binding.metadataName, '${r.key.dumpId}.meta.json');
    expect(published.sizeBytes, noteBytes.length);
    // T1: text notes publish into the 'Tangent Text Notes' child of the
    // chosen folder, never at the root.
    final noteDirectory =
        p.join(h.f.directory('A'), textNoteSubdirectoryName);
    expect(p.dirname(binding.audio.value), noteDirectory);
    final noteFile = File(p.join(noteDirectory, '${r.key.dumpId}.md'));
    expect(await noteFile.readAsBytes(), noteBytes);
    final sidecar = File(p.join(noteDirectory, '${r.key.dumpId}.meta.json'));
    expect(await sidecar.readAsBytes(), utf8.encode(metadata));
    // The backends' component resolution accepts the published .md audio
    // slot for read and deletion (note deletion capability, Task 10 proof).
    final read = requireOk(await settled(h.backend.readAudio(binding)));
    expect(read, noteBytes);
    final removed = await settled(
      h.backend.deleteComponent(
        binding,
        RecordingComponent.audio,
        'fixture-ext-delete',
      ),
    );
    expect(removed.state, ComponentState.removed, reason: '${removed.problem}');
    expect(await noteFile.exists(), isFalse);
  });

  test('brain_dump reservation still stages and publishes .opus', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'brain_dump'));
    expect(p.basename(r.stagingPath), '${r.id}.opus');
    final audio = [0x4f, 0x67, 0x67, 0x53, 2, 4];
    await File(r.stagingPath).writeAsBytes(audio, flush: true);
    final lease = requireOk(
      await h.mutations.acquire(
        r.key.dumpId,
        UseKind.capture,
        expectedIncarnation: r.key.incarnation,
      ),
    );
    late DumpRow row;
    try {
      row = await h.mutations.serialize(
        r.key,
        () => RecordingPersistence(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).save(
          r,
          RecordingResult(
            path: r.stagingPath,
            durationSeconds: 3,
            sizeBytes: audio.length,
          ),
          now: DateTime.utc(2030, 1, 2, 3, 4, 5),
          lease: lease,
        ),
      );
    } finally {
      await lease.close();
    }
    expect(p.basename(row.audioPath), '${r.key.dumpId}.opus');
    expect(await h.f.audio('A', row.id).readAsBytes(), audio);
  });

  test(
      'NEGATIVE: a .md staging file offered to an audio-mode reservation '
      'faults and creates nothing', () async {
    final root = Directory.systemTemp.createTempSync('tangent-ext-negative-');
    addTearDown(() => root.deleteSync(recursive: true));
    final destination = Directory(p.join(root.path, 'destination'))
      ..createSync();
    const id = 'fixture-ext-negative';
    final noteBytes = utf8.encode('markdown offered as audio');
    final staged = File(p.join(root.path, '$id.md'))
      ..writeAsBytesSync(noteBytes);
    final r = (
      id: id,
      key: (dumpId: '$id-dump', incarnation: '$id-incarnation'),
      location: fileLocation('fixture-root', destination.path),
      stagingPath: staged.path,
      mode: 'brain_dump',
      startedAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
      phase: CapturePhase.stopped
    );
    final metadata = jsonEncode({
      'schemaVersion': 2,
      'id': '$id-dump',
      'mode': 'brain_dump',
      'title': 'audio fixture',
    });
    final digest = sha256.convert(noteBytes).toString();
    final backend = FilesystemStorageBackend();
    addTearDown(() async {
      await backend.drain();
      await backend.acknowledgeCapturePreparation('capture-$id-prepare');
    });
    final result = await settled(
      backend.prepareCapture(
        r,
        metadata,
        digest,
        'capture-$id-prepare',
        observeOnly: false,
      ),
    );
    expect(result.state, CapturePreparationState.notStarted);
    expect(result.problem?.code, ProblemCode.invalid);
    expect(result.problem?.message, 'Incoherent filesystem capture input');
    expect(destination.listSync(), isEmpty,
        reason: 'audio-mode reservations must still REQUIRE .opus',);
    expect(staged.readAsBytesSync(), noteBytes,
        reason: 'failure paths preserve staged content',);
  });

  test('unknown mode still faults in reserveCapture and reservationMap',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final fail = await h.catalog.reserveCapture(mode: 'bogus_mode')
        as Fail<CaptureReservation>;
    expect(fail.problem.code, ProblemCode.invalid);
    expect(fail.problem.message, 'Invalid recording mode');
    final manual = (
      id: 'fixture-ext-unknown',
      key: (dumpId: 'fixture-ext-unknown-dump', incarnation: 'fixture-inc'),
      location: fileLocation('A', h.f.directory('A')),
      stagingPath: p.join(h.f.directory('stage'), 'fixture-ext-unknown.opus'),
      mode: 'bogus_mode',
      startedAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
      phase: CapturePhase.stopped
    );
    expect(
      () => CapturePublicationCodec.reservationMap(manual),
      throwsA(
        isA<StorageFault>()
            .having((e) => e.problem.code, 'code', ProblemCode.invalid)
            .having((e) => e.problem.message, 'message',
                'Invalid capture mode',),
      ),
    );
  });

  test(
      'cleanupCommitted deletes committed text_note staging (<id>.md) and '
      'removes the reservation', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'text_note'));
    final noteBytes = utf8.encode('committed note body');
    await File(r.stagingPath).writeAsBytes(noteBytes, flush: true);
    final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
    final binding = (
      key: r.key,
      location: r.location,
      audio: (
        kind: 'file',
        value: p.join(h.f.directory('A'), '${r.key.dumpId}.md')
      ),
      metadataName: '${r.key.dumpId}.meta.json'
    );
    await h.f.db.into(h.f.db.dumps).insert(DumpRow(
          id: r.key.dumpId,
          createdAt: now,
          updatedAt: now,
          mode: 'text_note',
          durationSeconds: 0,
          title: 'fixture note cleanup',
          transcript: 'committed note body',
          meetingNotes: null,
          audioPath: binding.audio.value,
          audioSizeBytes: noteBytes.length,
          syncStatus: 'local_only',
          syncAttempts: 0,
          transcriptionStatus: 'not_applicable',
          transcriptionAttempt: 0,
          transcriptionRequestId: null,
          transcriptionJobId: null,
          transcriptionError: null,
        ),);
    await h.f.db.bindRecording(binding);
    await h.f.db.customStatement(
      'UPDATE capture_reservations SET state=? WHERE reservation_id=?',
      ['committed', r.id],
    );
    final persistence = RecordingPersistence(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
    );
    await persistence.cleanupCommitted(r, binding);
    expect(await File(r.stagingPath).exists(), isFalse,
        reason: 'committed note staging must be deleted by cleanup',);
    final retained = await h.f.db.customSelect(
      'SELECT reservation_id FROM capture_reservations '
      'WHERE reservation_id = ?',
      variables: [Variable(r.id)],
    ).get();
    expect(retained, isEmpty,
        reason: 'committed reservation row must be removed after cleanup',);
  });

  test(
      'save() accepts a text_note .md staging source '
      '(never faults Invalid owned staging source)', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final r = requireOk(await h.catalog.reserveCapture(mode: 'text_note'));
    final noteBytes = utf8.encode('typed note through save()');
    await File(r.stagingPath).writeAsBytes(noteBytes, flush: true);
    final lease = requireOk(
      await h.mutations.acquire(
        r.key.dumpId,
        UseKind.capture,
        expectedIncarnation: r.key.incarnation,
      ),
    );
    try {
      final row = await h.mutations.serialize(
        r.key,
        () => RecordingPersistence(
          db: h.f.db,
          backend: h.backend,
          mutations: h.mutations,
        ).save(
          r,
          RecordingResult(
            path: r.stagingPath,
            durationSeconds: 0,
            sizeBytes: noteBytes.length,
          ),
          now: DateTime.utc(2030, 1, 2, 3, 4, 5),
          lease: lease,
        ),
      );
      // Full success is only reachable once note enumeration lands (a later
      // task); if save() completes, the published component must be the .md.
      expect(row.mode, 'text_note');
      expect(p.basename(row.audioPath), '${r.key.dumpId}.md');
    } on StorageFault catch (e) {
      // The staging ownership check must accept the owned .md source; only
      // later pipeline stages (e.g. published-entry enumeration, fixed in a
      // later task) may reject here.
      expect(
        e.problem.message,
        isNot('Invalid owned staging source'),
        reason: 'mode-aware staging validation must accept <id>.md '
            'for text_note reservations',
      );
    } finally {
      await lease.close();
    }
  });

  test(
      'component resolution still rejects a binding whose audio basename is '
      'not a mode-derived content name', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    const id = 'fixture-ext-foreign';
    final binding = (
      key: (dumpId: id, incarnation: '$id-incarnation'),
      location: fileLocation('A', h.f.directory('A')),
      audio: (kind: 'file', value: p.join(h.f.directory('A'), '$id.txt')),
      metadataName: '$id.meta.json'
    );
    final result = await settled(
      h.backend.deleteComponent(
        binding,
        RecordingComponent.audio,
        'fixture-ext-foreign-delete',
      ),
    );
    expect(result.state, ComponentState.failed);
    expect(result.problem?.code, ProblemCode.invalid);
    expect(
      result.problem?.message,
      'Binding does not identify exact owned components',
    );
  });
}

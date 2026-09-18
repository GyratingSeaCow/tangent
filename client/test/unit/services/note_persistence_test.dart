// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/recording_metadata.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/note_persistence.dart';
import 'package:tangent/services/recording_persistence.dart';
import '../../support/scripted_storage_backend.dart';

/// Task 4: NotePersistence stages typed text as UTF-8 `<id>.md` and drives
/// the existing owned-capture save pipeline. The committed row carries the
/// note body in `transcript` with `transcriptionStatus='not_applicable'`,
/// the published `.md` locator in `audioPath`, and the REAL `.md` byte
/// length in `audioSizeBytes` (journal coherence by construction).
void main() {
  NotePersistence notesFor(CatalogHarness h) => NotePersistence(
        db: h.f.db,
        backend: h.backend,
        mutations: h.mutations,
        catalog: h.catalog,
      );

  Future<int> reservationCount(CatalogHarness h) async => (await h.f.db
          .customSelect('SELECT reservation_id FROM capture_reservations')
          .get())
      .length;

  test('generatedNoteTitle formats Note yyyy-MM-dd HH-mm-ss', () {
    expect(
      generatedNoteTitle(DateTime(2030, 1, 2, 3, 4, 5)),
      'Note 2030-01-02 03-04-05',
    );
    expect(
      generatedNoteTitle(DateTime(2030, 11, 22, 13, 44, 55)),
      'Note 2030-11-22 13-44-55',
    );
  });

  test(
      'saveNote publishes <id>.md beside its sidecar and lands the note row '
      'field by field', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    const text = 'hello world';
    final bytes = utf8.encode(text);
    final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
    final row = await notesFor(h).saveNote(text: text, now: now);
    expect(row.mode, 'text_note');
    expect(row.title, generatedNoteTitle(now));
    expect(row.transcript, text);
    expect(row.transcriptionStatus, 'not_applicable');
    expect(row.durationSeconds, 0);
    expect(row.audioSizeBytes, bytes.length);
    expect(p.basename(row.audioPath), '${row.id}.md');
    expect(
      p.dirname(row.audioPath),
      p.join(h.f.directory('A'), textNoteSubdirectoryName),
      reason: 'notes publish into the Tangent Text Notes subdirectory',
    );
    expect(row.syncStatus, 'pending');
    final persisted = await h.f.db.getDump(row.id);
    expect(persisted, isNotNull);
    expect(persisted!.transcript, text);
    expect(persisted.transcriptionStatus, 'not_applicable');
    expect(persisted.title, generatedNoteTitle(now));
    expect(persisted.audioPath, row.audioPath);
    expect(persisted.audioSizeBytes, bytes.length);
    final noteDirectory =
        p.join(h.f.directory('A'), textNoteSubdirectoryName);
    final published = File(p.join(noteDirectory, '${row.id}.md'));
    expect(
      await published.readAsBytes(),
      bytes,
      reason: 'the published .md must hold the exact typed bytes',
    );
    final sidecar = File(p.join(noteDirectory, '${row.id}.meta.json'));
    final metadata =
        jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
    expect(metadata['mode'], 'text_note');
    expect(metadata['title'], generatedNoteTitle(now));
    expect(metadata['transcript'], text);
    expect(metadata['transcriptionStatus'], 'not_applicable');
    expect(
      metadata['audioSizeBytes'],
      bytes.length,
      reason: 'sidecar audioSizeBytes is the REAL .md byte length, never null',
    );
    expect(metadata['durationSeconds'], 0);
    expect(
      Directory(h.f.directory('stage')).listSync(),
      isEmpty,
      reason: 'committed note staging must be cleaned up',
    );
    expect(
      await reservationCount(h),
      0,
      reason: 'committed reservation must be removed',
    );
  });

  test(
      'blank or whitespace-only text throws ArgumentError before any '
      'reservation exists', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final notes = notesFor(h);
    for (final blank in ['', '   ', '\n\t  \n']) {
      await expectLater(
        notes.saveNote(text: blank, now: DateTime.utc(2030)),
        throwsArgumentError,
      );
    }
    expect(
      await reservationCount(h),
      0,
      reason: 'rejection must precede any reservation',
    );
    expect(Directory(h.f.directory('stage')).listSync(), isEmpty);
  });

  test(
      'publication fault: reopen + recoverOwnedCaptures restores the note '
      'row with transcript intact', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    const text = 'recoverable note body';
    final bytes = utf8.encode(text);
    final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
    h.backend.publication = (reservation, preparation) => ImmediateIo(
          'fixture-note-publish-fail',
          const Fail<PublishedCapture>(
            (code: ProblemCode.io, message: 'fixture note publication died'),
          ),
        );
    await expectLater(
      notesFor(h).saveNote(text: text, now: now),
      throwsA(
        isA<StorageFault>().having(
          (e) => e.problem.message,
          'message',
          'fixture note publication died',
        ),
      ),
    );
    final reservation = await h.f.db
        .customSelect('SELECT dump_id FROM capture_reservations')
        .getSingle();
    final dumpId = reservation.data['dump_id'] as String;
    expect(await h.f.db.getDump(dumpId), isNull);
    // Fresh app launch: new DB connection, new coordinator, real backend.
    await h.reopen();
    await h.mutations
        .restoreFences(unsettled: await h.f.backend.unsettledUses());
    final recovered = await RecordingPersistence(
      db: h.f.db,
      backend: h.f.backend,
      mutations: h.mutations,
    ).recoverOwnedCaptures();
    expect(recovered.problems, isEmpty);
    expect(recovered.recoveredIds, [dumpId]);
    final row = await h.f.db.getDump(dumpId);
    expect(row, isNotNull);
    expect(row!.mode, 'text_note');
    expect(row.transcript, text, reason: 'transcript must survive recovery');
    expect(row.transcriptionStatus, 'not_applicable');
    expect(row.title, generatedNoteTitle(now));
    expect(row.audioSizeBytes, bytes.length);
    expect(p.basename(row.audioPath), '$dumpId.md');
    expect(
      await File(
        p.join(h.f.directory('A'), textNoteSubdirectoryName, '$dumpId.md'),
      ).readAsBytes(),
      bytes,
    );
    expect(await reservationCount(h), 0);
  });
}

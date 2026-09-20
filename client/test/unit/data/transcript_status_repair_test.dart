// SPDX-License-Identifier: AGPL-3.0-or-later
/// The v11 -> v12 upgrade, which repairs transcription status on rows that
/// synced before the apply-site fix.
///
/// `applyRemoteDump` wrote the transcript text but left `transcription_status`
/// at its table default, so a recording arrived carrying its full transcript
/// while the list said "Not transcribed". Fixing the apply site does NOT heal
/// those rows: their `synced_seq` is already current, so the change feed never
/// replays them and the contradiction persists forever. On Jeff's own devices
/// that was 35 rows on the tablet and 37 on the Fold.
///
/// The repair must be surgical. Both devices also hold a text note whose
/// status is `not_applicable` and whose transcript column legitimately holds
/// the note body — widening the predicate to "has text" would relabel a typed
/// note as a transcribed recording.
library;

import 'dart:io';

// QueryRow, for reading a deliberately minimal fixture through raw SQL
// instead of Drift's generated mapper.
import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// The v11 dumps shape.
///
/// Built by letting Drift create the CURRENT schema and then stamping the
/// version back to 11, rather than hand-copying the DDL. A hand-written
/// fixture silently omits columns the generated mapper requires
/// (`sync_attempts`, `last_sync_error` were both missed here) and fails with
/// a null-check crash inside `$DumpsTable.map` that reads like a product bug.
/// v11 and v12 share an identical table shape — v12 only repairs DATA — so
/// the current schema is the correct v11 shape by construction.

/// Creates a v11 database by asking Drift for the CURRENT schema DDL and
/// replaying it into a fresh handle, then stamping the version back to 11.
///
/// Closing a `LocalDb` also closes the sqlite handle underneath it, so the
/// schema cannot be built in-place on the handle the test keeps. Read the DDL
/// out of one throwaway database and replay it into another.
Future<sqlite3.Database> _v11DatabaseAsync() async {
  final sqlite3.Database template = sqlite3.sqlite3.openInMemory();
  final LocalDb creator = LocalDb.forTesting(NativeDatabase.opened(template));
  await creator.listDumps();
  // FTS5 virtual tables create their own shadow tables (`*_fts_data`,
  // `_idx`, `_docsize`, `_config`), so replaying those alongside the
  // CREATE VIRTUAL TABLE fails with "table already exists". Keep the
  // virtual-table declaration and let sqlite rebuild its own shadows.
  final Set<String> shadowOwners = <String>{
    for (final sqlite3.Row row in template.select(
      "SELECT name FROM sqlite_master WHERE sql LIKE 'CREATE VIRTUAL TABLE%'",
    ))
      row['name'] as String,
  };
  final List<String> ddl = <String>[
    for (final sqlite3.Row row in template.select(
      'SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL '
      "AND name NOT LIKE 'sqlite_%'",
    ))
      if (!shadowOwners.any(
        (String owner) => (row['name'] as String).startsWith('${owner}_'),
      ))
        row['sql'] as String,
  ];
  await creator.close();

  final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
  for (final String statement in ddl) {
    raw.execute(statement);
  }
  raw.userVersion = 11;
  return raw;
}

void _insertDump(
  sqlite3.Database raw, {
  required String id,
  required String status,
  String? transcript,
  String mode = 'brain_dump',
  int syncedSeq = 42,
}) {
  raw.execute(
    'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
    'title, transcript, audio_path, audio_size_bytes, sync_status, '
    'transcription_status, transcription_attempt, synced_seq, remote_only) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      1758000000,
      1758000000,
      mode,
      9,
      'Recording $id',
      transcript,
      '',
      0,
      'synced',
      status,
      0,
      syncedSeq,
      1,
    ],
  );
}

void main() {
  test('a synced transcript stops claiming to be untranscribed', () async {
    final sqlite3.Database raw = await _v11DatabaseAsync();
    _insertDump(
      raw,
      id: 'synced-with-text',
      status: 'not_transcribed',
      transcript: 'real words that arrived from the server',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    final DumpRow row = (await db.getDumpRow('synced-with-text'))!;
    expect(row.transcriptionStatus, 'completed');
    expect(row.transcript, 'real words that arrived from the server');
  });

  test('a typed note is never relabelled as a transcribed recording', () async {
    final sqlite3.Database raw = await _v11DatabaseAsync();
    // Both of Jeff's devices hold one of these: the transcript column carries
    // the note body, and not_applicable is the correct, deliberate status.
    _insertDump(
      raw,
      id: 'text-note',
      status: 'not_applicable',
      transcript: 'this is a typed note, not speech',
      mode: 'text_note',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(
      (await db.getDumpRow('text-note'))!.transcriptionStatus,
      'not_applicable',
    );
  });

  test('a genuinely untranscribed recording is left alone', () async {
    final sqlite3.Database raw = await _v11DatabaseAsync();
    _insertDump(raw, id: 'no-text', status: 'not_transcribed');
    _insertDump(
      raw,
      id: 'blank-text',
      status: 'not_transcribed',
      transcript: '',
    );
    _insertDump(
      raw,
      id: 'whitespace',
      status: 'not_transcribed',
      transcript: '   \n  ',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    for (final String id in <String>['no-text', 'blank-text', 'whitespace']) {
      expect(
        (await db.getDumpRow(id))!.transcriptionStatus,
        'not_transcribed',
        reason: '\$id has no transcript, so nothing was repaired',
      );
    }
  });

  test('a failed transcription keeps its failure', () async {
    final sqlite3.Database raw = await _v11DatabaseAsync();
    // Silently flipping this to completed would hide a real failure from the
    // retry path.
    _insertDump(raw, id: 'failed-one', status: 'failed');
    _insertDump(
      raw,
      id: 'failed-with-partial',
      status: 'failed',
      transcript: 'partial text before the failure',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect((await db.getDumpRow('failed-one'))!.transcriptionStatus, 'failed');
    expect(
      (await db.getDumpRow('failed-with-partial'))!.transcriptionStatus,
      'failed',
    );
  });

  test('the repair does not disturb rows it is not meant to touch', () async {
    final sqlite3.Database raw = await _v11DatabaseAsync();
    _insertDump(
      raw,
      id: 'repaired',
      status: 'not_transcribed',
      transcript: 'server text',
    );
    _insertDump(
      raw,
      id: 'already-done',
      status: 'completed',
      transcript: 'already fine',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    final DumpRow repaired = (await db.getDumpRow('repaired'))!;
    // A status repair is not a user edit. Marking these dirty would push 37
    // pointless changes per device into the feed and fight the other device's
    // own repair.
    expect(repaired.syncDirty, isNot(true));
    expect(repaired.syncedSeq, 42);
    // Untouched timestamp: compare against the neighbouring row's value
    // rather than constructing one, since Drift maps stored seconds to local
    // time and the fixture wrote a UTC epoch.
    final DumpRow untouched = (await db.getDumpRow('already-done'))!;
    expect(repaired.updatedAt, untouched.updatedAt);

    expect(
      (await db.getDumpRow('already-done'))!.transcriptionStatus,
      'completed',
    );
  });

  test('the upgrade lands on v13 and keeps every row', () async {
    final sqlite3.Database raw = await _v11DatabaseAsync();
    for (int i = 0; i < 6; i++) {
      _insertDump(
        raw,
        id: 'dump-$i',
        status: i.isEven ? 'not_transcribed' : 'completed',
        transcript: 'text $i',
      );
    }

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(raw.userVersion, 13);
    final List<DumpRow> all = await db.select(db.dumps).get();
    expect(all, hasLength(6));
    expect(
      all.every((DumpRow r) => r.transcriptionStatus == 'completed'),
      isTrue,
      reason: 'all six carry text, so all six read as transcribed',
    );
  });

  test('a database older than the dumps status column still upgrades',
      () async {
    // Regression: the repair originally ran a bare UPDATE, which threw
    // "no such column: transcription_status" on a v7/v9 database, because
    // migrations run in sequence and this step is reached before the column
    // exists. That bricks app launch for the oldest installs. 13 existing
    // migration tests caught it; none of this file's own tests could, since
    // they all start at v11. Starts at v7 with the tables the intermediate
    // steps expect, so the failure it guards is the status column and not a
    // missing-table artifact of the fixture.
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute('''
      CREATE TABLE dumps (
        id TEXT NOT NULL PRIMARY KEY,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        mode TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL,
        title TEXT NOT NULL,
        audio_path TEXT NOT NULL,
        audio_size_bytes INTEGER NOT NULL,
        sync_status TEXT NOT NULL
      );
      CREATE TABLE notebooks (
        id TEXT NOT NULL PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        doc_json TEXT NOT NULL,
        ink_json TEXT NOT NULL
      );
    ''');
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
      'title, audio_path, audio_size_bytes, sync_status) VALUES '
      "('ancient', 1750000000, 1750000000, 'brain_dump', 30, 'Old one', "
      "'/storage/emulated/0/Tangent/ancient.opus', 1024, 'local_only')",
    );
    raw.userVersion = 7;

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // Read through raw SQL, not Drift's typed mapper: this deliberately
    // minimal fixture omits unrelated columns the generated mapper requires,
    // and the claim under test is only that the upgrade COMPLETES.
    final List<QueryRow> rows = await db
        .customSelect('SELECT id, title, audio_path FROM dumps')
        .get();

    expect(raw.userVersion, 13);
    expect(rows, hasLength(1));
    expect(rows.single.data['id'], 'ancient');
    expect(rows.single.data['title'], 'Old one');
    expect(
      rows.single.data['audio_path'],
      '/storage/emulated/0/Tangent/ancient.opus',
      reason: 'an old recording must keep pointing at its audio',
    );
  });

  test('running the upgrade twice changes nothing the second time', () async {
    // Drift registers native SQL functions on open and cannot re-register
    // them on the same raw handle, so a genuine reopen means a file-backed
    // database rather than a second wrapper over one in-memory handle.
    final Directory dir = await Directory.systemTemp.createTemp('tangent-v12');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}/tangent.sqlite');

    final sqlite3.Database seed = sqlite3.sqlite3.open(file.path);
    final LocalDb creator = LocalDb.forTesting(NativeDatabase.opened(seed));
    await creator.listDumps();
    await creator.close();

    final sqlite3.Database staged = sqlite3.sqlite3.open(file.path);
    staged.execute('DELETE FROM dumps');
    staged.userVersion = 11;
    _insertDump(
      staged,
      id: 'stable',
      status: 'not_transcribed',
      transcript: 'server text',
    );
    staged.dispose();

    final LocalDb first = LocalDb.forTesting(NativeDatabase(file));
    await first.listDumps();
    final DumpRow after = (await first.getDumpRow('stable'))!;
    expect(after.transcriptionStatus, 'completed');
    await first.close();

    // Reopen at v12: the repair must not run again, and must not undo itself.
    final LocalDb second = LocalDb.forTesting(NativeDatabase(file));
    addTearDown(second.close);
    await second.listDumps();

    final DumpRow again = (await second.getDumpRow('stable'))!;
    expect(again.transcriptionStatus, 'completed');
    expect(again.updatedAt, after.updatedAt);
    expect(again.syncDirty, isNot(true));
  });
}

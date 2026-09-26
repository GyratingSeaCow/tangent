// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:tangent/data/local_db.dart';

import '../../support/resolved_temp.dart';

/// The diagnostics snapshot exists so a release build on a phone (no
/// `run-as`, no debugger) can still hand over its exact local state:
/// `VACUUM INTO` writes a consistent copy of the whole database, WAL
/// included, to a path the user can pull without root. It carries dump
/// metadata only — audio never lives in this file.
void main() {
  late Directory tmp;

  setUp(() => tmp = createResolvedTempSync('tangent-diag'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes a self-contained copy that another connection can read',
      () async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.applyRemoteDump(
      id: 'd1',
      mode: 'brain_dump',
      title: 'Snapshot me',
      transcript: 'Testing, testing, testing.',
      meetingNotes: null,
      durationSeconds: 5,
      audioOnServer: true,
      createdAt: DateTime.utc(2026, 9, 13),
      updatedAt: DateTime.utc(2026, 9, 26),
      transcriptTimings: '{"segments":[],"peaks":[]}',
      seq: 7,
    );

    final target = File('${tmp.path}${Platform.pathSeparator}snapshot.sqlite');
    final written = await db.writeDiagnosticSnapshot(target);

    expect(written.path, target.path);
    expect(written.existsSync(), isTrue);
    expect(written.lengthSync(), greaterThan(0));

    // Read it back with a plain sqlite handle: no drift, no app schema
    // knowledge, exactly what a human with sqlite3 would do.
    final raw =
        sqlite.sqlite3.open(written.path, mode: sqlite.OpenMode.readOnly);
    addTearDown(raw.dispose);
    final rows = raw.select(
      'SELECT id, transcript_timings, synced_seq FROM dumps WHERE id = ?',
      ['d1'],
    );
    expect(rows.single['transcript_timings'], '{"segments":[],"peaks":[]}');
    expect(rows.single['synced_seq'], 7);
    expect(raw.select('PRAGMA user_version').single.values.single, 18);
  });

  test('overwrites a stale snapshot instead of failing on it', () async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final target = File('${tmp.path}${Platform.pathSeparator}snapshot.sqlite')
      ..writeAsStringSync('stale bytes from last time');

    final written = await db.writeDiagnosticSnapshot(target);

    final raw =
        sqlite.sqlite3.open(written.path, mode: sqlite.OpenMode.readOnly);
    addTearDown(raw.dispose);
    expect(raw.select('PRAGMA user_version').single.values.single, 18);
  });
}

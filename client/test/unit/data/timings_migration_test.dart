// SPDX-License-Identifier: AGPL-3.0-or-later
/// The v17 -> v18 upgrade: `transcript_timings` on dumps (tap-to-hear).
///
/// Same hazard class as every migration test here: a repeat addColumn on
/// an existing install throws "duplicate column name" and the app can no
/// longer open its own database. The step must ask the database, never
/// trust the version number.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// The v17 dumps shape: the summary columns present, timings absent.
const String _dumpsV17 = '''
  CREATE TABLE dumps (
    id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT,
    meeting_notes TEXT,
    audio_path TEXT NOT NULL,
    audio_size_bytes INTEGER NOT NULL,
    sync_status TEXT NOT NULL,
    sync_attempts INTEGER NOT NULL DEFAULT 0,
    last_sync_error TEXT,
    transcription_status TEXT NOT NULL DEFAULT 'not_transcribed',
    transcription_request_id TEXT,
    transcription_job_id TEXT,
    transcription_attempt INTEGER NOT NULL DEFAULT 0,
    transcription_started_at INTEGER,
    transcription_updated_at INTEGER,
    transcription_completed_at INTEGER,
    transcription_error TEXT,
    folder_id TEXT,
    sync_dirty INTEGER,
    synced_seq INTEGER,
    remote_only INTEGER,
    audio_on_server INTEGER,
    summary TEXT,
    summary_model TEXT,
    summarized_at INTEGER,
    PRIMARY KEY (id)
  );
''';

sqlite3.Database _v17Database() {
  final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
  raw.execute(_dumpsV17);
  raw.execute('PRAGMA user_version = 17;');
  return raw;
}

Set<String> _columns(sqlite3.Database sql, String table) => <String>{
      for (final sqlite3.Row row in sql.select("PRAGMA table_info('$table')"))
        row['name'] as String,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v17 recording survives the upgrade and gains a NULL timings column',
      () async {
    final sqlite3.Database raw = _v17Database();
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, '
      'duration_seconds, title, transcript, audio_path, audio_size_bytes, '
      "sync_status, summary) VALUES ('old-dump', 100, 200, 'brain_dump', 60, "
      "'Idea', 'we talked', '/audio/idea.opus', 4096, 'synced', '# S');",
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(raw.userVersion, 18);
    expect(_columns(raw, 'dumps'), contains('transcript_timings'));
    final DumpRow row = (await db.getDump('old-dump'))!;
    expect(row.transcript, 'we talked', reason: 'existing data survives');
    expect(row.summary, '# S', reason: 'v17 columns untouched');
    expect(row.transcriptTimings, isNull,
        reason: 'no timings were ever produced for this row',);
  });

  test('the upgrade is safe when the timings column somehow already exists',
      () async {
    final sqlite3.Database raw = _v17Database();
    raw.execute('ALTER TABLE dumps ADD COLUMN transcript_timings TEXT;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(raw.userVersion, 18);
    expect(_columns(raw, 'dumps'), contains('transcript_timings'));
  });

  test('applyRemoteDump: absent key keeps timings, present null erases them',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final DateTime t = DateTime.utc(2026, 9, 25);
    Future<void> apply({Object? timings = LocalDb.absentSummaryField}) =>
        db.applyRemoteDump(
          id: 'd1',
          mode: 'brain_dump',
          title: 'T',
          transcript: 'hello',
          meetingNotes: null,
          durationSeconds: 3,
          audioOnServer: true,
          createdAt: t,
          updatedAt: t,
          seq: 1,
          transcriptTimings: timings,
        );

    await apply(
        timings:
            '{"segments":[{"start":0,"end":1,"text":"hello","words":[]}]}',);
    expect((await db.getDump('d1'))!.transcriptTimings, contains('hello'));

    await apply(); // older server: key absent
    expect((await db.getDump('d1'))!.transcriptTimings, contains('hello'),
        reason: 'absence is not an eraser',);

    await apply(timings: null); // server says: none
    expect((await db.getDump('d1'))!.transcriptTimings, isNull,
        reason: 'an explicit null is authoritative',);
  });
}

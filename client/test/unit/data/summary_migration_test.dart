// SPDX-License-Identifier: AGPL-3.0-or-later
/// The v16 -> v17 upgrade, which adds the AI-summary columns to dumps.
///
/// A fresh schema passing its own tests proves nothing about an existing
/// install. The risk lives on the upgrade path: a second `addColumn` on a
/// table that already has the column throws "duplicate column name" and
/// leaves the app unable to open its own database — the bug class every
/// migration step in local_db.dart guards against by asking the database
/// instead of trusting the version number.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// The v16 dumps shape: everything the current table has EXCEPT the three
/// summary columns this migration adds.
const String _dumpsV16 = '''
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
    PRIMARY KEY (id)
  );
''';

sqlite3.Database _v16Database() {
  final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
  raw.execute(_dumpsV16);
  raw.execute('PRAGMA user_version = 16;');
  return raw;
}

Set<String> _columns(sqlite3.Database sql, String table) => <String>{
      for (final sqlite3.Row row in sql.select("PRAGMA table_info('$table')"))
        row['name'] as String,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v16 recording survives the upgrade and gains NULL summary columns',
      () async {
    final sqlite3.Database raw = _v16Database();
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, '
      'duration_seconds, title, transcript, audio_path, audio_size_bytes, '
      "sync_status) VALUES ('old-dump', 100, 200, 'meeting', 60, "
      "'Standup', 'we talked', '/audio/standup.opus', 4096, 'synced');",
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    // The upgrade runs to the CURRENT schema, past 17 (v18 added timings).
    expect(raw.userVersion, 19);
    expect(
      _columns(raw, 'dumps'),
      containsAll(<String>['summary', 'summary_model', 'summarized_at']),
    );
    final DumpRow row = (await db.getDump('old-dump'))!;
    expect(row.title, 'Standup', reason: 'existing data must survive');
    expect(row.transcript, 'we talked');
    expect(row.audioPath, '/audio/standup.opus');
    // No summary was ever generated for this row; the columns must say so
    // honestly rather than defaulting to anything.
    expect(row.summary, isNull);
    expect(row.summaryModel, isNull);
    expect(row.summarizedAt, isNull);
  });

  test('the upgrade is safe when a summary column somehow already exists',
      () async {
    // Ask-the-database, never the version number: adding a column twice
    // throws "duplicate column name" and bricks app launch.
    final sqlite3.Database raw = _v16Database();
    raw.execute('ALTER TABLE dumps ADD COLUMN summary TEXT;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    // The upgrade runs to the CURRENT schema, past 17 (v18 added timings).
    expect(raw.userVersion, 19);
    expect(
      _columns(raw, 'dumps'),
      containsAll(<String>['summary', 'summary_model', 'summarized_at']),
    );
  });
}

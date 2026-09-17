// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:sqlite3/sqlite3.dart';

Database oldStorageDatabase(int version, {String? path}) {
  if (version != 3 && version != 4) throw ArgumentError.value(version);
  final db = path == null ? sqlite3.openInMemory() : sqlite3.open(path);
  db.execute('''
CREATE TABLE dumps (
 id TEXT NOT NULL PRIMARY KEY, created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL, mode TEXT NOT NULL,
 duration_seconds INTEGER NOT NULL, title TEXT NOT NULL,
 transcript TEXT, meeting_notes TEXT, audio_path TEXT NOT NULL,
 audio_size_bytes INTEGER NOT NULL, sync_status TEXT NOT NULL,
 sync_attempts INTEGER NOT NULL DEFAULT 0, last_sync_error TEXT
);
CREATE TABLE sync_queue (
 id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
 dump_id TEXT NOT NULL REFERENCES dumps(id) ON DELETE CASCADE,
 queued_at INTEGER NOT NULL
);
CREATE VIRTUAL TABLE dumps_fts USING fts5(
 title, transcript, content='dumps', content_rowid='rowid'
);
CREATE TRIGGER dumps_ai AFTER INSERT ON dumps BEGIN
 INSERT INTO dumps_fts(rowid,title,transcript) VALUES(new.rowid,new.title,new.transcript);
END;
CREATE TRIGGER dumps_ad AFTER DELETE ON dumps BEGIN
 INSERT INTO dumps_fts("dumps_fts",rowid,title,transcript)
 VALUES('delete',old.rowid,old.title,old.transcript);
END;
CREATE TRIGGER dumps_au AFTER UPDATE ON dumps BEGIN
 INSERT INTO dumps_fts("dumps_fts",rowid,title,transcript)
 VALUES('delete',old.rowid,old.title,old.transcript);
 INSERT INTO dumps_fts(rowid,title,transcript) VALUES(new.rowid,new.title,new.transcript);
END;
''');
  if (version == 4) {
    for (final definition in <String>[
      "transcription_status TEXT NOT NULL DEFAULT 'not_transcribed'",
      'transcription_request_id TEXT',
      'transcription_job_id TEXT',
      'transcription_attempt INTEGER NOT NULL DEFAULT 0',
      'transcription_started_at INTEGER',
      'transcription_updated_at INTEGER',
      'transcription_completed_at INTEGER',
      'transcription_error TEXT',
    ]) {
      db.execute('ALTER TABLE dumps ADD COLUMN $definition');
    }
  }
  const statuses = ['local_only', 'pending', 'syncing', 'synced', 'failed'];
  const transcripts = [null, '', '   ', 'retained words', 'other words'];
  const transcriptions = [
    'not_transcribed',
    'uploading',
    'queued',
    'running',
    'completed',
    'failed',
  ];
  for (var i = 0; i < 10; i++) {
    db.execute('''INSERT INTO dumps
(id,created_at,updated_at,mode,duration_seconds,title,transcript,meeting_notes,
 audio_path,audio_size_bytes,sync_status,sync_attempts,last_sync_error)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)''', [
      'fixture-$i',
      1000 + i,
      2000 + i,
      i.isEven ? 'meeting' : 'brain_dump',
      7 + i,
      'Searchable fixture $i',
      transcripts[i % transcripts.length],
      'preserve notes $i',
      'content://fixture/tree/root/document/audio-$i',
      10 + i,
      statuses[i % statuses.length],
      i,
      i.isEven ? null : 'old sync error',
    ]);
    if (version == 4) {
      db.execute(
          '''UPDATE dumps SET transcription_status=?,transcription_request_id=?,
transcription_job_id=?,transcription_attempt=?,transcription_started_at=?,
transcription_updated_at=?,transcription_completed_at=?,transcription_error=? WHERE id=?''',
          [
            transcriptions[i % transcriptions.length],
            i.isEven ? null : 'request-$i',
            i.isEven ? null : 'job-$i',
            i,
            3000 + i,
            4000 + i,
            i.isEven ? null : 5000 + i,
            i == 4
                ? 'sidecar_sync_pending: fixture'
                : (i == 5 ? 'retained diagnostic' : null),
            'fixture-$i',
          ]);
    }
    db.execute(
      'INSERT INTO sync_queue(dump_id,queued_at) VALUES(?,?)',
      ['fixture-$i', 6000 + i],
    );
  }
  db.userVersion = version;
  return db;
}

List<Map<String, Object?>> sqlRows(Database db, String table) => db
    .select('SELECT * FROM $table ORDER BY id')
    .map((r) => Map<String, Object?>.from(r))
    .toList();

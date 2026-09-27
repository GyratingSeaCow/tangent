// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client DB v21 (v1.18.0): `dumps.summary_requested_at`, the local-only
/// "summary in progress" marker. Stamped by the summarize 202, cleared by
/// the sync apply that delivers a summary at least that new, never pushed.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// The v20 dumps shape: every column up to speaker_names.
const String _dumpsV20 = '''
  CREATE TABLE dumps (
    id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT NULL,
    meeting_notes TEXT NULL,
    audio_path TEXT NOT NULL,
    audio_size_bytes INTEGER NOT NULL,
    sync_status TEXT NOT NULL DEFAULT 'local_only',
    sync_attempts INTEGER NOT NULL DEFAULT 0,
    last_sync_error TEXT NULL,
    remote_only INTEGER NULL,
    audio_on_server INTEGER NULL,
    sync_dirty INTEGER NULL,
    synced_seq INTEGER NULL,
    transcription_status TEXT NOT NULL DEFAULT 'not_transcribed',
    transcription_attempt INTEGER NOT NULL DEFAULT 0,
    transcription_started_at INTEGER NULL,
    transcription_completed_at INTEGER NULL,
    transcription_error TEXT NULL,
    transcription_owner_device_id TEXT NULL,
    transcription_run_id TEXT NULL,
    storage_key TEXT NULL,
    folder_id TEXT NULL,
    summary TEXT NULL,
    summary_model TEXT NULL,
    summarized_at INTEGER NULL,
    transcript_timings TEXT NULL,
    summary_template TEXT NULL,
    speaker_names TEXT NULL,
    PRIMARY KEY (id)
  );
  CREATE TABLE settings (key TEXT NOT NULL, value TEXT NOT NULL,
    PRIMARY KEY (key));
''';

Set<String> _columns(sqlite3.Database sql, String table) => <String>{
      for (final sqlite3.Row row in sql.select("PRAGMA table_info('$table')"))
        row['name'] as String,
    };

DumpRow _row(String id, {String? summary, int? summarizedAt}) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26),
      mode: 'meeting',
      durationSeconds: 4,
      title: 'Planning',
      audioPath: '/audio/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'synced',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 1,
      transcript: 'hello',
      summary: summary,
      summarizedAt: summarizedAt,
      summaryTemplate: summary == null ? null : 'meeting',
    );

Future<void> _applyServerSummary(
  LocalDb db,
  String id, {
  required String summary,
  required int summarizedAt,
}) =>
    db.applyRemoteDump(
      id: id,
      mode: 'meeting',
      title: 'Planning',
      transcript: 'hello',
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26, 0, 5),
      seq: 9,
      summary: summary,
      summaryModel: 'Qwen3-4B-Instruct-2507-Q4_K_M',
      summarizedAt: summarizedAt,
      summaryTemplate: 'lecture',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 2026-09-26T12:00:00Z as unix seconds.
  const int t0 = 1790424000;
  final DateTime requestedAt =
      DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);

  test('v20 -> v21 adds summary_requested_at, null on existing rows',
      () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV20);
    raw.execute('PRAGMA user_version = 20;');
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
      'title, transcript, audio_path, audio_size_bytes, summary, '
      "summarized_at) VALUES ('old', 100, 200, 'meeting', 60, 'Old', 'words', "
      "'/audio/x.opus', 1, '## Summary\nkept', 150)",
    );
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(raw.userVersion, 24);
    expect(_columns(raw, 'dumps'), contains('summary_requested_at'));
    final DumpRow row = (await db.getDump('old'))!;
    expect(row.summaryRequestedAt, isNull);
    expect(row.summary, '## Summary\nkept', reason: 'data untouched');
    expect(row.summarizedAt, 150);
  });

  test('the v21 step is safe when the column already exists', () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV20);
    raw.execute('ALTER TABLE dumps ADD COLUMN summary_requested_at INTEGER;');
    raw.execute('PRAGMA user_version = 20;');
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await expectLater(db.listDumps(), completes);
    expect(raw.userVersion, 24);
  });

  test('recordRequestedSummaryTemplate stamps template AND requested_at, '
      'not dirty, updated_at untouched', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final DumpRow seeded =
        _row('r-1', summary: '## Summary\nold', summarizedAt: t0 - 500);
    await db.into(db.dumps).insert(seeded);

    await db.recordRequestedSummaryTemplate('r-1', 'lecture', now: requestedAt);

    final DumpRow after = (await db.getDump('r-1'))!;
    expect(after.summaryTemplate, 'lecture');
    expect(after.summaryRequestedAt, t0);
    expect(after.syncDirty ?? false, isFalse);
    expect(
      after.updatedAt.millisecondsSinceEpoch,
      seeded.updatedAt.millisecondsSinceEpoch,
    );
    expect(after.summary, '## Summary\nold', reason: 'preserve-until-success');
    expect(after.summarizedAt, t0 - 500);
  });

  test('applyRemoteDump with a summarized_at >= requested clears the marker',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(
          _row('r-2', summary: '## Summary\nold', summarizedAt: t0 - 500),
        );
    await db.recordRequestedSummaryTemplate('r-2', 'lecture', now: requestedAt);
    expect((await db.getDump('r-2'))!.summaryRequestedAt, t0);

    await _applyServerSummary(
      db,
      'r-2',
      summary: '## Summary\nnew',
      summarizedAt: t0 + 45,
    );

    final DumpRow after = (await db.getDump('r-2'))!;
    expect(after.summaryRequestedAt, isNull, reason: 'the answer landed');
    expect(after.summary, '## Summary\nnew');
    expect(after.summarizedAt, t0 + 45);
    expect(after.summaryTemplate, 'lecture');
  });

  test('applyRemoteDump with summarized_at EQUAL to requested clears it too',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(_row('r-3'));
    await db.recordRequestedSummaryTemplate('r-3', 'meeting', now: requestedAt);

    await _applyServerSummary(db, 'r-3', summary: '## S', summarizedAt: t0);

    expect((await db.getDump('r-3'))!.summaryRequestedAt, isNull);
  });

  test('applyRemoteDump with an OLDER summarized_at leaves the marker',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(
          _row('r-4', summary: '## Summary\nold', summarizedAt: t0 - 500),
        );
    await db.recordRequestedSummaryTemplate('r-4', 'lecture', now: requestedAt);

    // A stale echo: a peer's change carrying the PREVIOUS summary.
    await _applyServerSummary(
      db,
      'r-4',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
    );

    final DumpRow after = (await db.getDump('r-4'))!;
    expect(after.summaryRequestedAt, t0, reason: 'still waiting');
  });

  test('applyRemoteDump without summary keys (older server) leaves the marker',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(_row('r-5'));
    await db.recordRequestedSummaryTemplate('r-5', 'lecture', now: requestedAt);

    await db.applyRemoteDump(
      id: 'r-5',
      mode: 'meeting',
      title: 'Renamed',
      transcript: 'hello',
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26, 0, 5),
      seq: 10,
    );

    final DumpRow after = (await db.getDump('r-5'))!;
    expect(after.title, 'Renamed');
    expect(after.summaryRequestedAt, t0);
  });
}

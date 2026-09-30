// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client DB v22 (v1.19.0): the translation columns (`language`,
/// `translated`) and summary status columns (`summary_status`,
/// `summary_error`, `summary_queue_position`) the server authors, plus the
/// local-only `summary_error_dismissed_at`. `applyRemoteDump` lets the
/// server's verdict end the local "in progress" guess on a failure and
/// spends the dismissed marker on the next success / attempt.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

/// The v21 dumps shape: every column up to summary_requested_at.
const String _dumpsV21 = '''
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
    summary_requested_at INTEGER NULL,
    PRIMARY KEY (id)
  );
  CREATE TABLE settings (key TEXT NOT NULL, value TEXT NOT NULL,
    PRIMARY KEY (key));
''';

const List<String> _v22Columns = <String>[
  'language',
  'translated',
  'summary_status',
  'summary_error',
  'summary_queue_position',
  'summary_error_dismissed_at',
];

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

/// A pulled change carrying the server's summary verdict. [summaryStatus]
/// is always PRESENT here (a v1.19.0 server sends the key on every change;
/// null means idle/done).
Future<void> _applyServerSummary(
  LocalDb db,
  String id, {
  required String? summary,
  required int? summarizedAt,
  required String? summaryStatus,
  String? summaryError,
  int? summaryQueuePosition,
  int seq = 9,
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
      seq: seq,
      summary: summary,
      summaryModel: summary == null ? null : 'Qwen3-4B-Instruct-2507-Q4_K_M',
      summarizedAt: summarizedAt,
      summaryTemplate: summary == null ? null : 'meeting',
      summaryStatus: summaryStatus,
      summaryError: summaryError,
      summaryQueuePosition: summaryQueuePosition,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 2026-09-26T12:00:00Z as unix seconds.
  const int t0 = 1790424000;
  final DateTime requestedAt =
      DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);
  final DateTime dismissedAt =
      DateTime.fromMillisecondsSinceEpoch((t0 + 30) * 1000, isUtc: true);

  test('v21 -> v22 adds all six columns, null on existing rows', () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV21);
    raw.execute('PRAGMA user_version = 21;');
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
      'title, transcript, audio_path, audio_size_bytes, summary, '
      "summarized_at, summary_requested_at) VALUES ('old', 100, 200, "
      "'meeting', 60, 'Old', 'words', '/audio/x.opus', 1, "
      "'## Summary\nkept', 150, 160)",
    );
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await db.listDumps();

    expect(raw.userVersion, 28);
    final Set<String> columns = _columns(raw, 'dumps');
    for (final String column in _v22Columns) {
      expect(columns, contains(column), reason: '$column is the v22 add');
    }
    final DumpRow row = (await db.getDump('old'))!;
    expect(row.language, isNull);
    expect(row.translated, isNull);
    expect(row.summaryStatus, isNull);
    expect(row.summaryError, isNull);
    expect(row.summaryQueuePosition, isNull);
    expect(row.summaryErrorDismissedAt, isNull);
    expect(row.summary, '## Summary\nkept', reason: 'data untouched');
    expect(row.summarizedAt, 150);
    expect(row.summaryRequestedAt, 160);
  });

  test('the v22 step is safe when the columns already exist', () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV21);
    raw.execute('ALTER TABLE dumps ADD COLUMN language TEXT;');
    raw.execute('ALTER TABLE dumps ADD COLUMN translated INTEGER;');
    raw.execute('ALTER TABLE dumps ADD COLUMN summary_status TEXT;');
    raw.execute('ALTER TABLE dumps ADD COLUMN summary_error TEXT;');
    raw.execute('ALTER TABLE dumps ADD COLUMN summary_queue_position INTEGER;');
    raw.execute(
      'ALTER TABLE dumps ADD COLUMN summary_error_dismissed_at INTEGER;',
    );
    raw.execute('PRAGMA user_version = 21;');
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);
    await expectLater(db.listDumps(), completes);
    expect(raw.userVersion, 28);
    expect(_columns(raw, 'dumps'), containsAll(_v22Columns));
  });

  test('applyRemoteDump stores the five server-authored fields', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(_row('s-0'));

    await db.applyRemoteDump(
      id: 's-0',
      mode: 'meeting',
      title: 'Planning',
      transcript: 'hola',
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26, 0, 5),
      seq: 3,
      language: 'es',
      translated: 1,
      summaryStatus: 'queued',
      summaryError: null,
      summaryQueuePosition: 2,
    );

    final DumpRow row = (await db.getDump('s-0'))!;
    expect(row.language, 'es');
    expect(row.translated, isTrue, reason: 'wire 1 reads as true');
    expect(row.summaryStatus, 'queued');
    expect(row.summaryError, isNull);
    expect(row.summaryQueuePosition, 2);
    expect(row.syncDirty ?? false, isFalse);
  });

  test("applyRemoteDump with summary_status='failed' clears the local "
      'summary_requested_at marker (the server verdict ends the request)',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(
          _row('s-1', summary: '## Summary\nold', summarizedAt: t0 - 500),
        );
    await db.recordRequestedSummaryTemplate('s-1', 'lecture', now: requestedAt);
    expect((await db.getDump('s-1'))!.summaryRequestedAt, t0);

    // The failure publish: the old summary echoes back unchanged (its
    // summarized_at is OLDER than the request), status says failed.
    await _applyServerSummary(
      db,
      's-1',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: 'failed',
      summaryError: 'RuntimeError: model missing',
    );

    final DumpRow after = (await db.getDump('s-1'))!;
    expect(after.summaryStatus, 'failed');
    expect(after.summaryError, 'RuntimeError: model missing');
    expect(
      after.summaryRequestedAt,
      isNull,
      reason: 'a failed verdict ends the local "in progress" guess',
    );
    expect(after.summary, '## Summary\nold', reason: 'old body stays');
    expect(after.summarizedAt, t0 - 500);
  });

  test('a queued/running publish with an older summarized_at leaves the '
      'requested marker (still in progress)', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(
          _row('s-2', summary: '## Summary\nold', summarizedAt: t0 - 500),
        );
    await db.recordRequestedSummaryTemplate('s-2', 'lecture', now: requestedAt);

    await _applyServerSummary(
      db,
      's-2',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: 'queued',
      summaryQueuePosition: 1,
    );
    expect((await db.getDump('s-2'))!.summaryRequestedAt, t0);

    await _applyServerSummary(
      db,
      's-2',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: 'running',
      seq: 10,
    );
    expect((await db.getDump('s-2'))!.summaryRequestedAt, t0);
  });

  test('dismissSummaryError stamps summary_error_dismissed_at only: not '
      'dirty, updated_at untouched, status kept', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final DumpRow seeded =
        _row('s-3', summary: '## Summary\nold', summarizedAt: t0 - 500);
    await db.into(db.dumps).insert(seeded);
    await _applyServerSummary(
      db,
      's-3',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: 'failed',
      summaryError: 'boom',
    );
    final DateTime updatedAtBefore = (await db.getDump('s-3'))!.updatedAt;

    await db.dismissSummaryError('s-3', now: dismissedAt);

    final DumpRow after = (await db.getDump('s-3'))!;
    expect(after.summaryErrorDismissedAt, t0 + 30);
    expect(after.summaryStatus, 'failed', reason: 'the verdict is untouched');
    expect(after.summaryError, 'boom');
    expect(after.syncDirty ?? false, isFalse, reason: 'local-only');
    expect(
      after.updatedAt.millisecondsSinceEpoch,
      updatedAtBefore.millisecondsSinceEpoch,
    );
  });

  test('a successful summary (status null, summarized_at advances) clears '
      'summary_error_dismissed_at so the NEXT failure shows again', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(
          _row('s-4', summary: '## Summary\nold', summarizedAt: t0 - 500),
        );
    await _applyServerSummary(
      db,
      's-4',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: 'failed',
      summaryError: 'boom',
    );
    await db.dismissSummaryError('s-4', now: dismissedAt);
    expect((await db.getDump('s-4'))!.summaryErrorDismissedAt, t0 + 30);

    await _applyServerSummary(
      db,
      's-4',
      summary: '## Summary\nnew',
      summarizedAt: t0 + 90,
      summaryStatus: null,
      seq: 10,
    );

    final DumpRow after = (await db.getDump('s-4'))!;
    expect(after.summary, '## Summary\nnew');
    expect(after.summarizedAt, t0 + 90);
    expect(after.summaryStatus, isNull);
    expect(
      after.summaryErrorDismissedAt,
      isNull,
      reason: 'success spends the dismissal',
    );
  });

  test('a stale echo (status null, summarized_at NOT newer) keeps the '
      'dismissal', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(
          _row('s-5', summary: '## Summary\nold', summarizedAt: t0 - 500),
        );
    await _applyServerSummary(
      db,
      's-5',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: 'failed',
      summaryError: 'boom',
    );
    await db.dismissSummaryError('s-5', now: dismissedAt);

    // The same old summary, no status: nothing new happened server-side.
    await _applyServerSummary(
      db,
      's-5',
      summary: '## Summary\nold',
      summarizedAt: t0 - 500,
      summaryStatus: null,
      seq: 10,
    );

    expect((await db.getDump('s-5'))!.summaryErrorDismissedAt, t0 + 30);
  });

  test('a new attempt (queued / running) clears the dismissal too', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(_row('s-6'));
    await _applyServerSummary(
      db,
      's-6',
      summary: null,
      summarizedAt: null,
      summaryStatus: 'failed',
      summaryError: 'boom',
    );
    await db.dismissSummaryError('s-6', now: dismissedAt);
    expect((await db.getDump('s-6'))!.summaryErrorDismissedAt, t0 + 30);

    await _applyServerSummary(
      db,
      's-6',
      summary: null,
      summarizedAt: null,
      summaryStatus: 'queued',
      summaryQueuePosition: 3,
      seq: 10,
    );
    final DumpRow queued = (await db.getDump('s-6'))!;
    expect(queued.summaryErrorDismissedAt, isNull);
    expect(queued.summaryQueuePosition, 3);

    await db.dismissSummaryError('s-6', now: dismissedAt);
    await _applyServerSummary(
      db,
      's-6',
      summary: null,
      summarizedAt: null,
      summaryStatus: 'running',
      seq: 11,
    );
    expect((await db.getDump('s-6'))!.summaryErrorDismissedAt, isNull);
  });

  test('recordRequestedSummaryTemplate (a fresh local request) clears the '
      'dismissal', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(_row('s-7'));
    await _applyServerSummary(
      db,
      's-7',
      summary: null,
      summarizedAt: null,
      summaryStatus: 'failed',
      summaryError: 'boom',
    );
    await db.dismissSummaryError('s-7', now: dismissedAt);

    await db.recordRequestedSummaryTemplate('s-7', 'lecture', now: requestedAt);

    final DumpRow after = (await db.getDump('s-7'))!;
    expect(after.summaryErrorDismissedAt, isNull);
    expect(after.summaryRequestedAt, t0);
  });

  test('applyRemoteDump without the v1.19.0 keys (older server) keeps what '
      'we hold', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.dumps).insert(_row('s-8'));
    await db.applyRemoteDump(
      id: 's-8',
      mode: 'meeting',
      title: 'Planning',
      transcript: 'hola',
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26, 0, 5),
      seq: 3,
      language: 'es',
      translated: true,
      summaryStatus: 'failed',
      summaryError: 'boom',
    );
    await db.dismissSummaryError('s-8', now: dismissedAt);

    await db.applyRemoteDump(
      id: 's-8',
      mode: 'meeting',
      title: 'Renamed',
      transcript: 'hola',
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26, 0, 6),
      seq: 4,
    );

    final DumpRow after = (await db.getDump('s-8'))!;
    expect(after.title, 'Renamed');
    expect(after.language, 'es');
    expect(after.translated, isTrue, reason: 'wire true reads as true');
    expect(after.summaryStatus, 'failed');
    expect(after.summaryError, 'boom');
    expect(after.summaryErrorDismissedAt, t0 + 30);
  });
}

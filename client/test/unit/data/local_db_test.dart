// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/transcription_status.dart';

void main() {
  group('TranscriptionStatus', () {
    test('exposes the exact durable wire states and predicates', () {
      expect(
        TranscriptionStatus.fromWire('not_transcribed'),
        TranscriptionStatus.notTranscribed,
      );
      expect(TranscriptionStatus.uploading.isInProgress, isTrue);
      expect(TranscriptionStatus.queued.isInProgress, isTrue);
      expect(TranscriptionStatus.running.isInProgress, isTrue);
      expect(TranscriptionStatus.completed.isTerminal, isTrue);
      expect(TranscriptionStatus.failed.isTerminal, isTrue);
      expect(
        TranscriptionStatus.values.map((status) => status.wireValue),
        [
          'not_transcribed',
          'uploading',
          'queued',
          'running',
          'completed',
          'failed',
        ],
      );
    });
  });

  group('LocalDb', () {
    late LocalDb db;

    setUp(() {
      db = LocalDb.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('inserts and retrieves a dump', () async {
      final row = DumpRow(
        id: 'test-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Test',
        transcript: 'Raw words',
        meetingNotes: 'Structured notes',
        audioPath: '/tmp/test.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
        syncAttempts: 0,
        transcriptionStatus: 'not_transcribed',
        transcriptionAttempt: 0,
      );
      await db.upsertDump(row);

      final fetched = await db.getDump('test-1');
      expect(fetched, isNotNull);
      expect(fetched!.title, 'Test');
      expect(fetched.mode, 'brain_dump');
      expect(fetched.transcript, 'Raw words');
      expect(fetched.meetingNotes, 'Structured notes');
    });

    test('lists dumps newest first', () async {
      for (var i = 0; i < 3; i++) {
        await db.upsertDump(
          DumpRow(
            id: 'test-$i',
            createdAt: DateTime.utc(2026, 1, 1 + i),
            updatedAt: DateTime.utc(2026, 1, 1 + i),
            mode: 'brain_dump',
            durationSeconds: 60,
            title: 'Test $i',
            audioPath: '/tmp/$i.opus',
            audioSizeBytes: 1000,
            syncStatus: 'local_only',
            syncAttempts: 0,
            transcriptionStatus: 'not_transcribed',
            transcriptionAttempt: 0,
          ),
        );
      }
      final list = await db.listDumps();
      expect(list.length, 3);
      expect(list.first.id, 'test-2');
      expect(list.last.id, 'test-0');
    });

    test('searches by title using FTS5', () async {
      await db.upsertDump(
        DumpRow(
          id: 'test-1',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          mode: 'brain_dump',
          durationSeconds: 60,
          title: 'Deployment strategy thoughts',
          audioPath: '/tmp/test.opus',
          audioSizeBytes: 1000,
          syncStatus: 'local_only',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      await db.upsertDump(
        DumpRow(
          id: 'test-2',
          createdAt: DateTime.utc(2026, 1, 2),
          updatedAt: DateTime.utc(2026, 1, 2),
          mode: 'brain_dump',
          durationSeconds: 60,
          title: 'Lunch ideas',
          audioPath: '/tmp/test2.opus',
          audioSizeBytes: 1000,
          syncStatus: 'local_only',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );

      final results = await db.searchDumps('deployment');
      expect(results.length, 1);
      expect(results.first.id, 'test-1');
    });

    test('migrates v1 FTS delete triggers to SQL string literals', () async {
      await db.close();
      final sqlite = sqlite3.openInMemory();
      sqlite.execute('''
        CREATE TABLE dumps (
          id TEXT NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          mode TEXT NOT NULL,
          duration_seconds INTEGER NOT NULL,
          title TEXT NOT NULL,
          transcript TEXT,
          audio_path TEXT NOT NULL,
          audio_size_bytes INTEGER NOT NULL,
          sync_status TEXT NOT NULL,
          sync_attempts INTEGER NOT NULL DEFAULT 0,
          last_sync_error TEXT
        );
        CREATE TABLE sync_queue (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          dump_id TEXT NOT NULL REFERENCES dumps(id) ON DELETE CASCADE,
          queued_at INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE dumps_fts USING fts5(
          title, transcript, content='dumps', content_rowid='rowid'
        );
        CREATE TRIGGER dumps_ad AFTER DELETE ON dumps BEGIN
          INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
          VALUES("delete", old.rowid, old.title, old.transcript);
        END;
        CREATE TRIGGER dumps_au AFTER UPDATE ON dumps BEGIN
          INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
          VALUES("delete", old.rowid, old.title, old.transcript);
          INSERT INTO dumps_fts(rowid, title, transcript)
          VALUES(new.rowid, new.title, new.transcript);
        END;
        PRAGMA user_version = 1;
      ''');
      final migrated = LocalDb.forTesting(NativeDatabase.opened(sqlite));
      addTearDown(migrated.close);

      await migrated.listDumps();

      final trigger = sqlite
          .select(
            "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'dumps_au'",
          )
          .single['sql'] as String;
      expect(trigger, contains("VALUES ('delete'"));
      expect(sqlite.userVersion, 4);
    });

    test('migrates v2 by adding meeting notes without changing transcript',
        () async {
      await db.close();
      final sqlite = sqlite3.openInMemory();
      sqlite.execute('''
        CREATE TABLE dumps (
          id TEXT NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          mode TEXT NOT NULL,
          duration_seconds INTEGER NOT NULL,
          title TEXT NOT NULL,
          transcript TEXT,
          audio_path TEXT NOT NULL,
          audio_size_bytes INTEGER NOT NULL,
          sync_status TEXT NOT NULL,
          sync_attempts INTEGER NOT NULL DEFAULT 0,
          last_sync_error TEXT
        );
        CREATE TABLE sync_queue (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          dump_id TEXT NOT NULL REFERENCES dumps(id) ON DELETE CASCADE,
          queued_at INTEGER NOT NULL
        );
        INSERT INTO dumps VALUES(
          'meeting-1', 1, 1, 'meeting', 30, 'Legacy meeting',
          'Raw legacy transcript', '/legacy.opus', 123, 'pending', 0, NULL
        );
        PRAGMA user_version = 2;
      ''');
      final migrated = LocalDb.forTesting(NativeDatabase.opened(sqlite));
      addTearDown(migrated.close);

      final row = await migrated.getDump('meeting-1');

      expect(sqlite.userVersion, 4);
      expect(row!.transcript, 'Raw legacy transcript');
      expect(row.meetingNotes, isNull);
      expect(row.syncStatus, 'local_only');
      expect(
        sqlite
            .select("PRAGMA table_info('dumps')")
            .map((column) => column['name']),
        contains('meeting_notes'),
      );
    });

    test(
        'migrating v2 keeps already-synced meetings synced and clears stale '
        'errors on demoted ones', () async {
      await db.close();
      final sqlite = sqlite3.openInMemory();
      sqlite.execute('''
        CREATE TABLE dumps (
          id TEXT NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          mode TEXT NOT NULL,
          duration_seconds INTEGER NOT NULL,
          title TEXT NOT NULL,
          transcript TEXT,
          audio_path TEXT NOT NULL,
          audio_size_bytes INTEGER NOT NULL,
          sync_status TEXT NOT NULL,
          sync_attempts INTEGER NOT NULL DEFAULT 0,
          last_sync_error TEXT
        );
        CREATE TABLE sync_queue (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          dump_id TEXT NOT NULL REFERENCES dumps(id) ON DELETE CASCADE,
          queued_at INTEGER NOT NULL
        );
        INSERT INTO dumps VALUES(
          'm-synced', 1, 1, 'meeting', 30, 'Synced meeting',
          'Synced transcript', '/synced.opus', 1, 'synced', 0, NULL
        );
        INSERT INTO dumps VALUES(
          'm-pending', 2, 2, 'meeting', 30, 'Pending meeting',
          'Pending transcript', '/pending.opus', 1, 'pending', 1, NULL
        );
        INSERT INTO dumps VALUES(
          'm-failed', 3, 3, 'meeting', 30, 'Failed meeting',
          'Failed transcript', '/failed.opus', 1, 'failed', 2, '401'
        );
        INSERT INTO dumps VALUES(
          'b-synced', 4, 4, 'brain_dump', 30, 'Brain',
          'Brain transcript', '/brain.opus', 1, 'synced', 0, NULL
        );
        PRAGMA user_version = 2;
      ''');
      final migrated = LocalDb.forTesting(NativeDatabase.opened(sqlite));
      addTearDown(migrated.close);

      final synced = await migrated.getDump('m-synced');
      final pending = await migrated.getDump('m-pending');
      final failed = await migrated.getDump('m-failed');
      final brain = await migrated.getDump('b-synced');

      expect(synced!.syncStatus, 'synced');
      expect(synced.transcript, 'Synced transcript');
      expect(pending!.syncStatus, 'local_only');
      expect(pending.syncAttempts, 0);
      expect(pending.lastSyncError, isNull);
      expect(failed!.syncStatus, 'local_only');
      expect(failed.syncAttempts, 0);
      expect(failed.lastSyncError, isNull);
      expect(brain!.syncStatus, 'synced');
    });

    test('migrates v3 transcript state into durable v4 columns', () async {
      await db.close();
      final sqlite = sqlite3.openInMemory();
      sqlite.execute('''
        CREATE TABLE dumps (
          id TEXT NOT NULL PRIMARY KEY,
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
          last_sync_error TEXT
        );
        CREATE TABLE sync_queue (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          dump_id TEXT NOT NULL REFERENCES dumps(id) ON DELETE CASCADE,
          queued_at INTEGER NOT NULL
        );
        INSERT INTO dumps VALUES(
          'blank', 1000, 2000, 'brain_dump', 4, 'Blank',
          '   ', NULL, '/blank.opus', 1, 'pending', 0, NULL
        );
        INSERT INTO dumps VALUES(
          'done', 3000, 4000, 'brain_dump', 5, 'Done',
          'Existing transcript', NULL, '/done.opus', 1, 'synced', 0, NULL
        );
        PRAGMA user_version = 3;
      ''');
      final migrated = LocalDb.forTesting(NativeDatabase.opened(sqlite));
      addTearDown(migrated.close);

      final blank = await migrated.getDump('blank');
      final done = await migrated.getDump('done');

      expect(sqlite.userVersion, 4);
      expect(blank!.transcriptionStatus, 'not_transcribed');
      expect(blank.transcriptionAttempt, 0);
      expect(blank.transcriptionCompletedAt, isNull);
      expect(done!.transcriptionStatus, 'completed');
      expect(done.transcriptionCompletedAt, done.updatedAt);
      expect(done.transcriptionRequestId, isNull);
      expect(done.transcriptionJobId, isNull);
      expect(done.transcriptionStartedAt, isNull);
      expect(done.transcriptionUpdatedAt, isNull);
      expect(done.transcriptionError, isNull);
    });

    test('guards latest-attempt status and completion writes', () async {
      final now = DateTime.utc(2026, 9, 14, 18);
      await db.upsertDump(
        DumpRow(
          id: 'guarded',
          createdAt: now,
          updatedAt: now,
          mode: 'brain_dump',
          durationSeconds: 5,
          title: 'Guarded',
          audioPath: '/guarded.opus',
          audioSizeBytes: 1,
          syncStatus: 'pending',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );

      final first = await db.beginTranscriptionAttempt(
        'guarded',
        requestId: 'request-first',
        now: now,
      );
      final second = await db.beginTranscriptionAttempt(
        'guarded',
        requestId: 'request-second',
        now: now.add(const Duration(seconds: 1)),
      );
      final staleStatus = await db.updateTranscriptionStatus(
        'guarded',
        attempt: first.transcriptionAttempt,
        requestId: 'request-first',
        status: TranscriptionStatus.failed,
        now: now.add(const Duration(seconds: 2)),
        error: 'old failure',
      );
      final staleCompletion = await db.completeTranscriptionAttempt(
        'guarded',
        attempt: first.transcriptionAttempt,
        requestId: 'request-first',
        transcript: 'stale transcript',
        now: now.add(const Duration(seconds: 3)),
      );
      final currentStatus = await db.updateTranscriptionStatus(
        'guarded',
        attempt: second.transcriptionAttempt,
        requestId: 'request-second',
        status: TranscriptionStatus.running,
        now: now.add(const Duration(seconds: 4)),
        jobId: 'job-second',
      );
      final currentCompletion = await db.completeTranscriptionAttempt(
        'guarded',
        attempt: second.transcriptionAttempt,
        requestId: 'request-second',
        transcript: 'winning transcript',
        meetingNotes: 'winning notes',
        now: now.add(const Duration(seconds: 5)),
      );
      final saved = await db.getDump('guarded');

      expect(first.transcriptionAttempt, 1);
      expect(second.transcriptionAttempt, 2);
      expect(staleStatus, isFalse);
      expect(staleCompletion, isFalse);
      expect(currentStatus, isTrue);
      expect(currentCompletion, isTrue);
      expect(saved!.transcriptionRequestId, 'request-second');
      expect(saved.transcriptionJobId, 'job-second');
      expect(saved.transcriptionStatus, 'completed');
      expect(saved.transcript, 'winning transcript');
      expect(saved.meetingNotes, 'winning notes');
      expect(saved.transcriptionError, isNull);
      expect(
        saved.transcriptionCompletedAt!.toUtc(),
        now.add(const Duration(seconds: 5)),
      );
    });

    test('recovery query returns in-progress and sidecar-pending rows',
        () async {
      final now = DateTime.utc(2026, 9, 14);
      Future<void> insert(
        String id,
        TranscriptionStatus status, {
        String? error,
      }) {
        return db.upsertDump(
          DumpRow(
            id: id,
            createdAt: now,
            updatedAt: now,
            mode: 'brain_dump',
            durationSeconds: 1,
            title: id,
            transcript: status == TranscriptionStatus.completed ? 'done' : null,
            audioPath: '/$id.opus',
            audioSizeBytes: 1,
            syncStatus: 'pending',
            syncAttempts: 0,
            transcriptionStatus: status.wireValue,
            transcriptionAttempt:
                status == TranscriptionStatus.notTranscribed ? 0 : 1,
            transcriptionRequestId: status == TranscriptionStatus.notTranscribed
                ? null
                : 'request-$id',
            transcriptionError: error,
          ),
        );
      }

      await insert('uploading', TranscriptionStatus.uploading);
      await insert('queued', TranscriptionStatus.queued);
      await insert('running', TranscriptionStatus.running);
      await insert(
        'sidecar',
        TranscriptionStatus.completed,
        error: 'sidecar_sync_pending: write failed',
      );
      await insert('completed', TranscriptionStatus.completed);
      await insert('failed', TranscriptionStatus.failed);
      await insert('idle', TranscriptionStatus.notTranscribed);

      final rows = await db.dumpsNeedingTranscriptionRecovery();

      expect(
        rows.map((row) => row.id).toSet(),
        {'uploading', 'queued', 'running', 'sidecar'},
      );
    });
  });
}

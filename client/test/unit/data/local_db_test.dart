// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/recording_mutation_coordinator.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/transcription_status.dart';
import '../../support/bound_row_fixture.dart';

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
      // not_applicable is the terminal state for text notes, which are
      // never transcribed (spec: 2026-09-17-text-note-design data model).
      expect(TranscriptionStatus.notApplicable.isTerminal, isTrue);
      expect(TranscriptionStatus.notApplicable.isInProgress, isFalse);
      expect(
        TranscriptionStatus.values.map((status) => status.wireValue),
        [
          'not_transcribed',
          'uploading',
          'queued',
          'running',
          'completed',
          'failed',
          'not_applicable',
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
      await seedFileFixtureRow(db, row);

      final fetched = await db.getDump('test-1');
      expect(fetched, isNotNull);
      expect(fetched!.title, 'Test');
      expect(fetched.mode, 'brain_dump');
      expect(fetched.transcript, 'Raw words');
      expect(fetched.meetingNotes, 'Structured notes');
    });

    test('lists dumps newest first', () async {
      for (var i = 0; i < 3; i++) {
        await seedFileFixtureRow(
          db,
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
      await seedFileFixtureRow(
        db,
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
      await seedFileFixtureRow(
        db,
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
      expect(sqlite.userVersion, 5);
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

      expect(sqlite.userVersion, 5);
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

      expect(sqlite.userVersion, 5);
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
      await seedFileFixtureRow(
        db,
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
        storageKey: fileFixtureKey('guarded'),
        requestId: 'request-first',
        now: now,
      );
      await expectLater(
        db.beginTranscriptionAttempt(
          'guarded',
          storageKey: fileFixtureKey('guarded'),
          requestId: 'request-racing',
          now: now.add(const Duration(milliseconds: 500)),
        ),
        throwsStateError,
      );
      final firstFailure = await db.updateTranscriptionStatus(
        'guarded',
        storageKey: fileFixtureKey('guarded'),
        attempt: first.transcriptionAttempt,
        requestId: 'request-first',
        status: TranscriptionStatus.failed,
        now: now.add(const Duration(seconds: 1)),
        error: 'first attempt failed',
      );
      final second = await db.beginTranscriptionAttempt(
        'guarded',
        storageKey: fileFixtureKey('guarded'),
        requestId: 'request-second',
        now: now.add(const Duration(seconds: 2)),
      );
      final staleStatus = await db.updateTranscriptionStatus(
        'guarded',
        storageKey: fileFixtureKey('guarded'),
        attempt: first.transcriptionAttempt,
        requestId: 'request-first',
        status: TranscriptionStatus.failed,
        now: now.add(const Duration(seconds: 3)),
        error: 'old failure',
      );
      final staleCompletion = await db.completeTranscriptionAttempt(
        'guarded',
        storageKey: fileFixtureKey('guarded'),
        attempt: first.transcriptionAttempt,
        requestId: 'request-first',
        transcript: 'stale transcript',
        now: now.add(const Duration(seconds: 4)),
      );
      final currentStatus = await db.updateTranscriptionStatus(
        'guarded',
        storageKey: fileFixtureKey('guarded'),
        attempt: second.transcriptionAttempt,
        requestId: 'request-second',
        status: TranscriptionStatus.running,
        now: now.add(const Duration(seconds: 5)),
        jobId: 'job-second',
      );
      final currentCompletion = await db.completeTranscriptionAttempt(
        'guarded',
        storageKey: fileFixtureKey('guarded'),
        attempt: second.transcriptionAttempt,
        requestId: 'request-second',
        transcript: 'winning transcript',
        meetingNotes: 'winning notes',
        now: now.add(const Duration(seconds: 6)),
      );
      final saved = await db.getDump('guarded');

      expect(first.transcriptionAttempt, 1);
      expect(firstFailure, isTrue);
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
        now.add(const Duration(seconds: 6)),
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
        return seedFileFixtureRow(
          db,
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

    test('sidecar completion barrier blocks a newer attempt until cleared',
        () async {
      final now = DateTime.utc(2026, 9, 14, 20);
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'sidecar-barrier',
          createdAt: now,
          updatedAt: now,
          mode: 'brain_dump',
          durationSeconds: 5,
          title: 'Sidecar barrier',
          audioPath: '/sidecar-barrier.opus',
          audioSizeBytes: 1,
          syncStatus: 'pending',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      final attempt = await db.beginTranscriptionAttempt(
        'sidecar-barrier',
        storageKey: fileFixtureKey('sidecar-barrier'),
        requestId: 'request-sidecar',
        now: now,
      );

      final completed = await db.completeTranscriptionAttempt(
        'sidecar-barrier',
        storageKey: fileFixtureKey('sidecar-barrier'),
        attempt: attempt.transcriptionAttempt,
        requestId: 'request-sidecar',
        transcript: 'done',
        now: now.add(const Duration(seconds: 1)),
        sidecarError: 'sidecar_sync_pending: write pending',
      );
      final lateRunning = await db.updateTranscriptionStatus(
        'sidecar-barrier',
        storageKey: fileFixtureKey('sidecar-barrier'),
        attempt: attempt.transcriptionAttempt,
        requestId: 'request-sidecar',
        status: TranscriptionStatus.running,
        now: now.add(const Duration(milliseconds: 1500)),
        jobId: 'job-sidecar',
      );
      final pending = await db.getDump('sidecar-barrier');
      await expectLater(
        db.beginTranscriptionAttempt(
          'sidecar-barrier',
          storageKey: fileFixtureKey('sidecar-barrier'),
          requestId: 'request-too-early',
          now: now.add(const Duration(seconds: 2)),
        ),
        throwsStateError,
      );
      final cleared = await db.updateTranscriptionSidecarError(
        'sidecar-barrier',
        storageKey: fileFixtureKey('sidecar-barrier'),
        attempt: attempt.transcriptionAttempt,
        requestId: 'request-sidecar',
        error: null,
        now: now.add(const Duration(seconds: 3)),
      );
      final next = await db.beginTranscriptionAttempt(
        'sidecar-barrier',
        storageKey: fileFixtureKey('sidecar-barrier'),
        requestId: 'request-next',
        now: now.add(const Duration(seconds: 4)),
      );

      expect(completed, isTrue);
      expect(lateRunning, isFalse);
      expect(pending!.transcriptionStatus, 'completed');
      expect(
        pending.transcriptionError,
        'sidecar_sync_pending: write pending',
      );
      expect(cleared, isTrue);
      expect(next.transcriptionAttempt, 2);
    });

    test('completion ownership can be acquired only once per attempt',
        () async {
      final now = DateTime.utc(2026, 9, 14, 21);
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'single-completion-owner',
          createdAt: now,
          updatedAt: now,
          mode: 'brain_dump',
          durationSeconds: 5,
          title: 'Single completion owner',
          audioPath: '/single-completion-owner.opus',
          audioSizeBytes: 1,
          syncStatus: 'pending',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      final attempt = await db.beginTranscriptionAttempt(
        'single-completion-owner',
        storageKey: fileFixtureKey('single-completion-owner'),
        requestId: 'request-single-owner',
        now: now,
      );

      final first = await db.completeTranscriptionAttempt(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        transcript: 'winning transcript',
        now: now.add(const Duration(seconds: 1)),
        sidecarError: 'sidecar_sync_pending: write pending',
      );
      final duplicate = await db.completeTranscriptionAttempt(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        transcript: 'duplicate transcript',
        now: now.add(const Duration(seconds: 2)),
        sidecarError: 'sidecar_sync_pending: duplicate',
      );
      final saved = (await db.getDump(attempt.id))!;

      expect(first, isTrue);
      expect(duplicate, isFalse);
      expect(saved.transcript, 'winning transcript');
      expect(saved.transcriptionError, 'sidecar_sync_pending: write pending');
    });

    test('partial detail edits preserve durable transcription ownership',
        () async {
      final now = DateTime.utc(2026, 9, 14, 22);
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'partial-detail-edit',
          createdAt: now,
          updatedAt: now,
          mode: 'meeting',
          durationSeconds: 5,
          title: 'Original title',
          audioPath: '/partial-detail-edit.opus',
          audioSizeBytes: 1,
          syncStatus: 'pending',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      final attempt = await db.beginTranscriptionAttempt(
        'partial-detail-edit',
        storageKey: fileFixtureKey('partial-detail-edit'),
        requestId: 'request-partial-edit',
        now: now,
      );
      await db.updateTranscriptionStatus(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        status: TranscriptionStatus.running,
        jobId: 'job-partial-edit',
        now: now.add(const Duration(seconds: 1)),
      );

      await db.updateDumpTitle(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        title: 'Edited title',
        now: now.add(const Duration(seconds: 2)),
      );
      final running = (await db.getDump(attempt.id))!;
      expect(running.title, 'Edited title');
      expect(running.transcriptionStatus, 'running');
      expect(running.transcriptionAttempt, 1);
      expect(running.transcriptionRequestId, 'request-partial-edit');
      expect(running.transcriptionJobId, 'job-partial-edit');

      await db.completeTranscriptionAttempt(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        transcript: 'Current transcript',
        meetingNotes: 'Original notes',
        now: now.add(const Duration(seconds: 3)),
        sidecarError: 'sidecar_sync_pending: write pending',
      );
      await db.updateDumpMeetingNotes(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        expectedTitle: 'Edited title',
        expectedTranscript: 'Current transcript',
        expectedTranscriptionAttempt: attempt.transcriptionAttempt,
        expectedTranscriptionRequestId: attempt.transcriptionRequestId,
        meetingNotes: 'Edited notes',
        now: now.add(const Duration(seconds: 4)),
      );
      final completed = (await db.getDump(attempt.id))!;
      expect(completed.meetingNotes, 'Edited notes');
      expect(completed.transcript, 'Current transcript');
      expect(completed.transcriptionStatus, 'completed');
      expect(completed.transcriptionAttempt, 1);
      expect(completed.transcriptionRequestId, 'request-partial-edit');
      expect(completed.transcriptionJobId, 'job-partial-edit');
      expect(
        completed.transcriptionError,
        'sidecar_sync_pending: write pending',
      );
    });

    test('guarded transcript edit preserves notes and durable ownership',
        () async {
      final now = DateTime.utc(2026, 9, 15, 8);
      final original = DumpRow(
        id: 'editable-transcript',
        createdAt: now,
        updatedAt: now,
        mode: 'meeting',
        durationSeconds: 5,
        title: 'Editable transcript',
        transcript: 'Original words',
        meetingNotes: 'Keep these notes',
        audioPath: '/editable-transcript.opus',
        audioSizeBytes: 17,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionRequestId: 'request-editable',
        transcriptionJobId: 'job-editable',
        transcriptionAttempt: 3,
        transcriptionStartedAt: now,
        transcriptionUpdatedAt: now,
        transcriptionCompletedAt: now,
      );
      await seedFileFixtureRow(db, original);

      final saved = await db.updateDumpTranscript(
        original.id,
        storageKey: fileFixtureKey(original.id),
        expectedTranscript: original.transcript!,
        expectedTranscriptionAttempt: original.transcriptionAttempt,
        expectedTranscriptionRequestId: original.transcriptionRequestId,
        transcript: 'Corrected words',
        now: now.add(const Duration(minutes: 1)),
      );

      expect(saved.transcript, 'Corrected words');
      expect(saved.meetingNotes, 'Keep these notes');
      expect(saved.audioPath, '/editable-transcript.opus');
      expect(saved.audioSizeBytes, 17);
      expect(saved.transcriptionStatus, 'completed');
      expect(saved.transcriptionRequestId, 'request-editable');
      expect(saved.transcriptionJobId, 'job-editable');
      expect(saved.transcriptionAttempt, 3);
      expect(
        saved.transcriptionStartedAt!.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
      expect(
        saved.transcriptionCompletedAt!.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
    });

    test('note body edit succeeds against the not_applicable revision gate',
        () async {
      final now = DateTime.utc(2026, 9, 17, 9);
      final original = DumpRow(
        id: 'note-edit',
        createdAt: now,
        updatedAt: now,
        mode: 'text_note',
        durationSeconds: 0,
        title: 'Note 2026-09-17 09-00-00',
        transcript: 'First draft',
        audioPath: '/note-edit.md',
        audioSizeBytes: 11,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'not_applicable',
        transcriptionAttempt: 0,
      );
      await seedFileFixtureRow(db, original);

      final saved = await db.updateDumpTranscript(
        original.id,
        storageKey: fileFixtureKey(original.id),
        expectedTranscript: original.transcript!,
        expectedTranscriptionAttempt: 0,
        expectedTranscriptionRequestId: null,
        transcript: 'Edited note body',
        now: now.add(const Duration(minutes: 1)),
      );

      expect(saved.transcript, 'Edited note body');
      expect(saved.mode, 'text_note');
      expect(saved.transcriptionStatus, 'not_applicable');
      expect(
        saved.transcriptionError,
        startsWith('sidecar_sync_pending: manual_edit:'),
      );
    });

    test('note deletion claim and eligibility treat not_applicable as terminal',
        () async {
      final now = DateTime.utc(2026, 9, 17, 9, 30);
      final note = DumpRow(
        id: 'note-delete',
        createdAt: now,
        updatedAt: now,
        mode: 'text_note',
        durationSeconds: 0,
        title: 'Note 2026-09-17 09-30-00',
        transcript: 'Delete me',
        audioPath: '/note-delete.md',
        audioSizeBytes: 9,
        syncStatus: 'local_only',
        syncAttempts: 0,
        transcriptionStatus: 'not_applicable',
        transcriptionAttempt: 0,
      );
      final binding = await seedFileFixtureRow(db, note);
      final coordinator = DefaultRecordingMutationCoordinator(db: db);
      addTearDown(coordinator.drain);
      await coordinator.restoreFences();

      expect(
        (await coordinator.watchEligibility().first)[note.id],
        Eligibility.eligible,
      );
      final admission = await coordinator.acquire(note.id, UseKind.deletion);
      expect(admission, isA<Ok<UseLease>>());
      await (admission as Ok<UseLease>).value.close();

      final claimed = await db.claimLocalDeletion(
        'note-delete-op',
        (
          id: note.id,
          binding: binding,
          title: note.title,
          eligibility: Eligibility.eligible,
          retryTicketId: null,
        ),
      );
      expect(claimed, isA<Ok<DeletionTicket>>());
    });

    test(
        'fix round stale sidecar acknowledgement cannot clear a newer identical edit',
        () async {
      final now = DateTime.utc(2026, 9, 15);
      final original = DumpRow(
        id: 'manual-aba',
        createdAt: now,
        updatedAt: now,
        mode: 'meeting',
        durationSeconds: 1,
        title: 'ABA',
        transcript: 'Original',
        meetingNotes: 'Keep notes',
        audioPath: '/manual-aba.opus',
        audioSizeBytes: 3,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'failed',
        transcriptionAttempt: 0,
        transcriptionError: 'server rejection',
      );
      await seedFileFixtureRow(db, original);
      Future<DumpRow> edit(String expected, String value) =>
          db.updateDumpTranscript(
            original.id,
            storageKey: fileFixtureKey(original.id),
            expectedTranscript: expected,
            expectedTranscriptionAttempt: 0,
            expectedTranscriptionRequestId: null,
            transcript: value,
            now: now,
          );
      final first = await edit('Original', 'Edited');
      final second = await edit('Edited', 'Edited');
      expect(
        await db.updateTranscriptionSidecarError(
          original.id,
          storageKey: fileFixtureKey(original.id),
          attempt: 0,
          requestId: null,
          error: 'server rejection',
          now: now,
          expectedTranscript: first.transcript,
          expectedError: first.transcriptionError,
        ),
        isFalse,
      );
      expect(
        (await db.getDump(original.id))!.transcriptionError,
        second.transcriptionError,
      );
      await expectLater(
        db.beginTranscriptionAttempt(
          original.id,
          storageKey: fileFixtureKey(original.id),
          requestId: 'request-new',
          now: now,
        ),
        throwsStateError,
      );
      expect(
        LocalDb.errorAfterSidecarSync(second.transcriptionError),
        'server rejection',
      );
      expect(
        await db.updateTranscriptionSidecarError(
          original.id,
          storageKey: fileFixtureKey(original.id),
          attempt: 0,
          requestId: null,
          error: 'server rejection',
          now: now,
          expectedTranscript: second.transcript,
          expectedError: second.transcriptionError,
        ),
        isTrue,
      );
      final saved = (await db.getDump(original.id))!;
      expect(saved.transcriptionStatus, 'failed');
      expect(saved.meetingNotes, 'Keep notes');
      expect(saved.transcriptionError, 'server rejection');
    });

    test('transcript edit rejects blank, in-progress, and stale revisions',
        () async {
      final now = DateTime.utc(2026, 9, 15, 9);
      final original = DumpRow(
        id: 'guarded-transcript-edit',
        createdAt: now,
        updatedAt: now,
        mode: 'brain_dump',
        durationSeconds: 5,
        title: 'Guarded transcript',
        transcript: 'Original words',
        audioPath: '/guarded-transcript.opus',
        audioSizeBytes: 17,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionRequestId: 'request-one',
        transcriptionJobId: 'job-one',
        transcriptionAttempt: 1,
        transcriptionStartedAt: now,
        transcriptionUpdatedAt: now,
        transcriptionCompletedAt: now,
      );
      await seedFileFixtureRow(db, original);

      expect(
        () => db.updateDumpTranscript(
          original.id,
          storageKey: fileFixtureKey(original.id),
          expectedTranscript: original.transcript!,
          expectedTranscriptionAttempt: 1,
          expectedTranscriptionRequestId: 'request-one',
          transcript: '   \n ',
          now: now.add(const Duration(seconds: 1)),
        ),
        throwsArgumentError,
      );

      await db.beginTranscriptionAttempt(
        original.id,
        storageKey: fileFixtureKey(original.id),
        requestId: 'request-two',
        now: now.add(const Duration(seconds: 2)),
      );
      await expectLater(
        db.updateDumpTranscript(
          original.id,
          storageKey: fileFixtureKey(original.id),
          expectedTranscript: original.transcript!,
          expectedTranscriptionAttempt: 1,
          expectedTranscriptionRequestId: 'request-one',
          transcript: 'Stale corrected words',
          now: now.add(const Duration(seconds: 3)),
        ),
        throwsStateError,
      );
      expect((await db.getDump(original.id))!.transcript, 'Original words');
    });

    test('late nonterminal updates cannot regress a running phase', () async {
      final now = DateTime.utc(2026, 9, 14, 23, 30);
      await seedFileFixtureRow(
        db,
        DumpRow(
          id: 'monotonic-phase',
          createdAt: now,
          updatedAt: now,
          mode: 'brain_dump',
          durationSeconds: 5,
          title: 'Monotonic phase',
          audioPath: '/monotonic-phase.opus',
          audioSizeBytes: 1,
          syncStatus: 'pending',
          syncAttempts: 0,
          transcriptionStatus: 'not_transcribed',
          transcriptionAttempt: 0,
        ),
      );
      final attempt = await db.beginTranscriptionAttempt(
        'monotonic-phase',
        storageKey: fileFixtureKey('monotonic-phase'),
        requestId: 'request-monotonic',
        now: now,
      );
      final running = await db.updateTranscriptionStatus(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        status: TranscriptionStatus.running,
        jobId: 'job-monotonic',
        now: now.add(const Duration(seconds: 1)),
      );
      final lateQueued = await db.updateTranscriptionStatus(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        status: TranscriptionStatus.queued,
        jobId: 'job-monotonic',
        error: 'reconciliation_pending: late queued callback',
        now: now.add(const Duration(seconds: 2)),
      );
      final lateUploading = await db.updateTranscriptionStatus(
        attempt.id,
        storageKey: fileFixtureKey(attempt.id),
        attempt: attempt.transcriptionAttempt,
        requestId: attempt.transcriptionRequestId!,
        status: TranscriptionStatus.uploading,
        error: 'enqueue_pending: late upload callback',
        now: now.add(const Duration(seconds: 3)),
      );
      final saved = (await db.getDump(attempt.id))!;

      expect(running, isTrue);
      expect(lateQueued, isFalse);
      expect(lateUploading, isFalse);
      expect(saved.transcriptionStatus, 'running');
      expect(saved.transcriptionJobId, 'job-monotonic');
      expect(saved.transcriptionError, isNull);
    });
  });
}

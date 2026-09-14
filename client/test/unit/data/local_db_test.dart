// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';

void main() {
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
      expect(sqlite.userVersion, 3);
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

      expect(sqlite.userVersion, 3);
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
  });
}

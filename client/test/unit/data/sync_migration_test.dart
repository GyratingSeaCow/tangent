// SPDX-License-Identifier: AGPL-3.0-or-later
/// The v8 -> v9 upgrade, which adds multi-device sync.
///
/// A fresh schema passing its own tests proves nothing about an existing
/// install. The risk lives on the upgrade path, where a notebook someone has
/// been writing in for months meets two new columns — and where a second
/// `addColumn` on a table that already has them throws "duplicate column
/// name" and leaves the app unable to open its own database. That exact bug
/// shipped once already on the v6 -> v7 step.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';

const String _dumpsV8 = '''
  CREATE TABLE dumps (
    id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    audio_path TEXT NOT NULL,
    audio_size_bytes INTEGER NOT NULL,
    sync_status TEXT NOT NULL,
    folder_id TEXT,
    PRIMARY KEY (id)
  );
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v8 database with a notebook upgrades to v9 without losing it',
      () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV8);
    // The v8 shape: no sync_dirty, no synced_seq.
    raw.execute('''
      CREATE TABLE notebooks (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        doc_json TEXT NOT NULL,
        ink_json TEXT NOT NULL,
        folder_id TEXT,
        PRIMARY KEY (id)
      );
    ''');
    raw.execute(
      'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
      'ink_json) VALUES (\'nb-old\', \'Months of notes\', 100, 200, '
      '\'{"blocks":[{"kind":"text","text":"real work"}]}\', '
      '\'{"strokes":[1]}\');',
    );
    raw.execute('PRAGMA user_version = 8;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // Opening runs the migration.
    final List<NotebookRow> rows = await db.select(db.notebooks).get();

    expect(rows, hasLength(1), reason: 'the existing notebook must survive');
    expect(rows.single.title, 'Months of notes');
    expect(
      rows.single.docJson,
      '{"blocks":[{"kind":"text","text":"real work"}]}',
      reason: 'content must be carried across untouched',
    );
    expect(
      rows.single.inkJson,
      '{"strokes":[1]}',
      reason: 'the ink layer must survive the upgrade too',
    );
  });

  test('notebooks that predate sync are marked dirty so they reach the server',
      () async {
    // The quiet failure mode: a library that existed before sync was added is
    // marked clean, never pushed, and stays invisible on every other device
    // the user owns — with nothing on screen to reveal it.
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV8);
    raw.execute('''
      CREATE TABLE notebooks (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        doc_json TEXT NOT NULL,
        ink_json TEXT NOT NULL,
        folder_id TEXT,
        PRIMARY KEY (id)
      );
    ''');
    for (final String id in <String>['nb-1', 'nb-2', 'nb-3']) {
      raw.execute(
        'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
        'ink_json) VALUES (\'$id\', \'$id\', 1, 2, \'{}\', \'{}\');',
      );
    }
    raw.execute('PRAGMA user_version = 8;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final List<NotebookRow> pending = await db.notebooksNeedingPush();
    expect(
      pending.map((NotebookRow r) => r.id),
      containsAll(<String>['nb-1', 'nb-2', 'nb-3']),
      reason: 'every pre-existing notebook must be queued for its first push',
    );
  });

  test('a pre-notebooks database upgrades straight to v9 without colliding',
      () async {
    // createTable during an upgrade builds from the CURRENT definition, so the
    // notebooks table is born already carrying sync_dirty and synced_seq.
    // Adding them again throws and bricks the app on launch.
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV8);
    raw.execute('PRAGMA user_version = 5;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // Opening must not throw, and the database must be usable.
    expect(await db.select(db.notebooks).get(), isEmpty);
    expect(await db.pendingTombstones(), isEmpty);

    final SyncStateRow state = await db.syncState(newDeviceId: 'device-new');
    expect(state.deviceId, 'device-new');
    expect(state.lastPulledSeq, 0);
  });

  test('the upgraded database can record and clear a tombstone', () async {
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV8);
    raw.execute('PRAGMA user_version = 8;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    await db.recordTombstone(entityType: 'notebook', entityId: 'gone');
    expect(await db.pendingTombstones(), hasLength(1));
    await db.clearTombstone(entityType: 'notebook', entityId: 'gone');
    expect(await db.pendingTombstones(), isEmpty);
  });
}

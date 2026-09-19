// SPDX-License-Identifier: AGPL-3.0-or-later
/// The v9 -> v10 upgrade, which adds page ruling.
///
/// A fresh schema passing its own tests proves nothing about an existing
/// install. The risk lives on the upgrade path: a second `addColumn` on a
/// table that already has the column throws "duplicate column name" and
/// leaves the app unable to open its own database. That bug shipped once on
/// v6 -> v7, and the v8 -> v9 test caught a "no such table: notebooks"
/// variant of it before release.
library;

// Value<T> comes from drift; hide the matchers it also exports, which would
// otherwise shadow flutter_test's isNull/isNotNull.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/notebook_ruling.dart';

const String _dumpsV9 = '''
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

/// The v9 notebooks shape: has the sync columns, has no `ruling`.
const String _notebooksV9 = '''
  CREATE TABLE notebooks (
    id TEXT NOT NULL,
    title TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    doc_json TEXT NOT NULL,
    ink_json TEXT NOT NULL,
    folder_id TEXT,
    sync_dirty INTEGER NOT NULL DEFAULT 1,
    synced_seq INTEGER,
    PRIMARY KEY (id)
  );
''';

const String _syncTablesV9 = '''
  CREATE TABLE sync_tombstones (
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    PRIMARY KEY (entity_type, entity_id)
  );
  CREATE TABLE sync_states (
    id INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    last_seq INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
  );
''';

sqlite3.Database _v9Database() {
  final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
  raw.execute(_dumpsV9);
  raw.execute(_notebooksV9);
  raw.execute(_syncTablesV9);
  raw.execute('PRAGMA user_version = 9;');
  return raw;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a v9 notebook survives the upgrade to v10', () async {
    final sqlite3.Database raw = _v9Database();
    raw.execute(
      'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
      'ink_json) VALUES (\'nb-old\', \'Months of notes\', 100, 200, '
      '\'{"blocks":[{"kind":"text","text":"real work"}]}\', '
      '\'{"strokes":[1]}\');',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

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

  test('an upgraded notebook keeps rendering as a blank page', () async {
    // Silently ruling every page someone already owns would be the app
    // rewriting their notes' appearance without being asked.
    final sqlite3.Database raw = _v9Database();
    raw.execute(
      'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
      'ink_json) VALUES (\'nb-1\', \'Old\', 1, 2, \'{}\', \'{}\');',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final NotebookRow row = (await db.select(db.notebooks).get()).single;
    expect(row.ruling, isNull, reason: 'nothing to backfill');
    expect(
      NotebookRuling.parse(row.ruling),
      NotebookRuling.blank,
      reason: 'a page that has always been blank must stay blank',
    );
  });

  test('the upgrade does not disturb the sync state of existing rows',
      () async {
    // Ruling is cosmetic. If this migration marked notebooks dirty it would
    // push the entire library to the server for no reason.
    final sqlite3.Database raw = _v9Database();
    raw.execute(
      'INSERT INTO notebooks (id, title, created_at, updated_at, doc_json, '
      'ink_json, sync_dirty, synced_seq) '
      'VALUES (\'nb-clean\', \'Synced\', 1, 2, \'{}\', \'{}\', 0, 42);',
    );

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final NotebookRow row = (await db.select(db.notebooks).get()).single;
    expect(row.syncDirty, isFalse, reason: 'a clean notebook stays clean');
    expect(row.syncedSeq, 42, reason: 'the checkpoint must not be reset');
  });

  test('upgrading twice does not throw duplicate column name', () async {
    // Drift runs onUpgrade for every version below the current one. If a
    // database already carrying `ruling` reached the v10 step unguarded, the
    // addColumn would throw and the app could never open its own database.
    final sqlite3.Database raw = _v9Database();
    raw.execute('ALTER TABLE notebooks ADD COLUMN ruling TEXT;');
    raw.execute('PRAGMA user_version = 9;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    await expectLater(db.select(db.notebooks).get(), completes);
  });

  test('a v9 database with no notebooks table still upgrades', () async {
    // The version number is not evidence that a table exists. This is the
    // exact failure the v8 -> v9 test caught: "no such table: notebooks".
    final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
    raw.execute(_dumpsV9);
    raw.execute(_syncTablesV9);
    raw.execute('PRAGMA user_version = 9;');

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    await expectLater(db.select(db.notebooks).get(), completes);
  });

  test('a ruling written after the upgrade round-trips', () async {
    final sqlite3.Database raw = _v9Database();
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: 'nb-new',
            title: 'Ruled',
            createdAt: 1,
            updatedAt: 2,
            docJson: '{}',
            inkJson: '{}',
            ruling: const Value<String?>('medium'),
          ),
        );

    final NotebookRow row = (await db.select(db.notebooks).get()).single;
    expect(NotebookRuling.parse(row.ruling), NotebookRuling.medium);
  });
}

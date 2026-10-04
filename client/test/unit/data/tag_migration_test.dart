// SPDX-License-Identifier: AGPL-3.0-or-later
//
// v33 shared tags: two new tables, reachable from the OLDEST supported
// schema. Migrations run in sequence, so a step that only works on a v32
// database bricks launch for the oldest installs while every fresh-database
// test stays green — hence v3 and v4 here, not just v32.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';

import '../../support/storage_migration_fixture.dart';

Set<String> _columns(Database db, String table) => db
    .select('PRAGMA table_info($table)')
    .map((Row row) => row['name'] as String)
    .toSet();

Set<String> _indexes(Database db, String table) => db
    .select(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
      <Object?>[table],
    )
    .map((Row row) => row['name'] as String)
    .toSet();

void _expectTagSchema(Database sql) {
  expect(_columns(sql, 'tags'), <String>{
    'id',
    'name',
    'created_at',
    'updated_at',
    'sync_dirty',
    'synced_seq',
  });
  expect(_columns(sql, 'tag_assignments'), <String>{
    'id',
    'tag_id',
    'target_type',
    'target_id',
    'created_at',
    'sync_dirty',
    'synced_seq',
  });
  expect(
    _indexes(sql, 'tag_assignments'),
    containsAll(<String>[
      'tag_assignments_target_idx',
      'tag_assignments_tag_idx',
    ]),
  );
}

void main() {
  for (final int version in <int>[3, 4]) {
    test(
      'v$version upgrades to v33 with the tag tables and every dump intact',
      () async {
        final Database sql = oldStorageDatabase(version);
        sql.userVersion = version;
        final List<Map<String, Object?>> before = sql
            .select('SELECT id, title, transcript FROM dumps ORDER BY id')
            .map((Row r) => Map<String, Object?>.of(r))
            .toList();
        expect(before, hasLength(10));

        final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
        addTearDown(db.close);
        await db.listDumps();

        expect(sql.userVersion, 34);
        _expectTagSchema(sql);
        expect(
          sql
              .select('SELECT id, title, transcript FROM dumps ORDER BY id')
              .map((Row r) => Map<String, Object?>.of(r))
              .toList(),
          before,
        );
        expect(sql.select('PRAGMA integrity_check').single.values.single, 'ok');

        // The migrated tables are usable end to end, not merely present.
        final String tagId = await db.createTag('Work');
        await db.assignTag(
          tagId: tagId,
          targetType: LocalDb.tagTargetDump,
          targetId: 'fixture-0',
        );
        expect(await db.watchTagLinks(LocalDb.tagTargetDump).first, <TagLink>[
          (targetId: 'fixture-0', tagId: tagId),
        ]);
      },
    );
  }

  test('v32 gains the tag tables and touches no existing row', () async {
    final Database sql = sqlite3.openInMemory();
    final LocalDb seed = LocalDb.forTesting(
      NativeDatabase.opened(sql, closeUnderlyingOnClose: false),
    );
    await seed.listDumps();
    await seed.close();
    sql.execute(
      'INSERT INTO notebooks(id,title,created_at,updated_at,doc_json,ink_json) '
      "VALUES('n1','Kept',1,2,'{}','{}')",
    );
    sql.execute('DROP TABLE tag_assignments');
    sql.execute('DROP TABLE tags');
    sql.userVersion = 32;

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();

    expect(sql.userVersion, 34);
    _expectTagSchema(sql);
    final Row notebook = sql
        .select("SELECT title, sync_dirty FROM notebooks WHERE id='n1'")
        .single;
    expect(notebook['title'], 'Kept');
    expect(notebook['sync_dirty'], 1, reason: 'not re-dirtied, not cleaned');
  });

  test(
    'a sideways build that already created the tables upgrades cleanly',
    () async {
      final Database sql = sqlite3.openInMemory();
      final LocalDb seed = LocalDb.forTesting(
        NativeDatabase.opened(sql, closeUnderlyingOnClose: false),
      );
      await seed.listDumps();
      await seed.close();
      sql.execute(
        "INSERT INTO tags(id,name,created_at,updated_at) VALUES('t1','Kept',1,1)",
      );
      sql.userVersion = 32;

      final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
      addTearDown(db.close);
      await db.listDumps();

      expect(sql.userVersion, 34);
      expect(sql.select('SELECT name FROM tags').single['name'], 'Kept');
    },
  );

  test('a fresh database creates the tag tables and indexes', () async {
    final Database sql = sqlite3.openInMemory();
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();
    expect(sql.userVersion, 34);
    _expectTagSchema(sql);
  });
}

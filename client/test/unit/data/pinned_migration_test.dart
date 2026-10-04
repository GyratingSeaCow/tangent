// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';

Set<String> _columns(Database db, String table) => db
    .select('PRAGMA table_info($table)')
    .map((Row row) => row['name'] as String)
    .toSet();

void main() {
  test('v30 pin migration is guarded, order-tolerant, and preserves rows',
      () async {
    final Database sql = sqlite3.openInMemory();
    final LocalDb seed = LocalDb.forTesting(
      NativeDatabase.opened(sql, closeUnderlyingOnClose: false),
    );
    await seed.listDumps();
    await seed.close();

    sql.execute(
      'INSERT INTO notebooks(id,title,created_at,updated_at,doc_json,ink_json,pinned) '
      "VALUES('n1','Notebook',1,2,'{}','{}',1)",
    );
    sql.execute(
      'INSERT INTO todos(id,text,created_at,updated_at) '
      "VALUES('t1','Todo','2026-09-30T00:00:00Z','2026-09-30T00:00:00Z')",
    );
    sql.execute('ALTER TABLE dumps DROP COLUMN pinned');
    sql.execute('ALTER TABLE todos DROP COLUMN pinned');
    sql.userVersion = 27;

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();

    expect(sql.userVersion, 34);
    for (final String table in <String>['dumps', 'notebooks', 'todos']) {
      expect(_columns(sql, table), contains('pinned'), reason: table);
    }
    expect(
      sql.select("SELECT pinned FROM notebooks WHERE id='n1'").single['pinned'],
      1,
      reason: 'an already-migrated table is left untouched',
    );
    expect(
      sql.select("SELECT pinned FROM todos WHERE id='t1'").single['pinned'],
      isNull,
      reason: 'pre-v30 rows keep the old unpinned appearance',
    );
    expect(sql.select('PRAGMA integrity_check').single.values.single, 'ok');
  });
}

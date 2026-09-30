// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import '../../support/storage_migration_fixture.dart';

void main() {
  test('v26 to v27 preserves content and checkpoint and adds ask history',
      () async {
    final Database sql = oldStorageDatabase(4);
    sql.execute('''CREATE TABLE sync_state (
      id INTEGER NOT NULL DEFAULT 1 PRIMARY KEY,
      device_id TEXT NOT NULL,
      last_pulled_seq INTEGER NOT NULL DEFAULT 0,
      last_synced_at INTEGER NULL
    )''');
    sql.execute(
      "INSERT INTO sync_state(id,device_id,last_pulled_seq) VALUES(1,'device-kept',77)",
    );
    sql.userVersion = 26;
    sql.execute('DROP TABLE IF EXISTS ask_messages');
    final List<Map<String, Object?>> before = sqlRows(sql, 'dumps');
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();
    expect(sql.userVersion, 27);
    expect(sqlRows(sql, 'dumps'), before);
    expect(
      sql
          .select('SELECT last_pulled_seq FROM sync_state WHERE id=1')
          .single['last_pulled_seq'],
      77,
    );
    expect(
      sql.select("SELECT name FROM sqlite_master WHERE name='ask_messages'"),
      isNotEmpty,
    );
  });

  test('older supported migration path reaches v27 with ask table', () async {
    final Database sql = oldStorageDatabase(4);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();
    expect(sql.userVersion, 27);
    expect(
      sql.select("SELECT name FROM sqlite_master WHERE name='ask_messages'"),
      isNotEmpty,
    );
  });
}

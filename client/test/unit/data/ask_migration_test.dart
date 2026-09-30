// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

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
    expect(sql.userVersion, 28);
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

  test('older supported migration path reaches v28 with ask tables', () async {
    final Database sql = oldStorageDatabase(4);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();
    expect(sql.userVersion, 28);
    expect(
      sql.select("SELECT name FROM sqlite_master WHERE name='ask_messages'"),
      isNotEmpty,
    );
    expect(
      sql.select(
        "SELECT name FROM sqlite_master WHERE name='ask_source_visits'",
      ),
      isNotEmpty,
    );
  });

  test('v27 to v28 adds ask_source_visits and keeps ask history rows',
      () async {
    final Database sql = oldStorageDatabase(4);
    // Create the v27 shape by hand: ask_messages present, visits table absent.
    sql.execute('''CREATE TABLE ask_messages (
      id TEXT NOT NULL PRIMARY KEY,
      role TEXT NOT NULL,
      text TEXT NOT NULL,
      sources_json TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL,
      server_seq INTEGER NOT NULL
    )''');
    sql.execute(
      'INSERT INTO ask_messages(id,role,text,sources_json,created_at,server_seq)'
      " VALUES('m-1','assistant','kept','[]',1,1)",
    );
    sql.execute('DROP TABLE IF EXISTS ask_source_visits');
    sql.userVersion = 27;

    final LocalDb db = LocalDb.forTesting(NativeDatabase.opened(sql));
    addTearDown(db.close);
    await db.listDumps();

    expect(sql.userVersion, 28);
    expect(
      sql.select(
        "SELECT name FROM sqlite_master WHERE name='ask_source_visits'",
      ),
      isNotEmpty,
    );
    // The pull-only history survived the migration untouched.
    expect(sql.select('SELECT id FROM ask_messages').single['id'], 'm-1');
  });

  test('a recorded visit survives reopening the database', () async {
    // A real file, because the point is that the row outlives the connection.
    final Directory dir = Directory.systemTemp.createTempSync('ask-visits');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File file = File('${dir.path}/tangent.sqlite');

    final LocalDb first = LocalDb.forTesting(NativeDatabase(file));
    await first.listDumps();
    await first.markAskSourceVisited(messageId: 'm-9', sourceIndex: 2);
    expect(await first.askSourceVisitKeys(), <String>{'m-9#2'});
    // Idempotent: opening the same citation twice does not un-visit it.
    await first.markAskSourceVisited(messageId: 'm-9', sourceIndex: 2);
    expect(await first.askSourceVisitKeys(), <String>{'m-9#2'});
    await first.close();

    // A fresh connection over the same file is what an app restart looks like.
    final LocalDb reopened = LocalDb.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(await reopened.askSourceVisitKeys(), <String>{'m-9#2'});
  });
}

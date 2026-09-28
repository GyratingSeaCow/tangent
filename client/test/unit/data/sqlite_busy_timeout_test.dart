// SPDX-License-Identifier: AGPL-3.0-or-later
/// Two connections on one SQLite file must WAIT for each other, not throw.
///
/// The app and the WorkManager isolates (document sync, the daily reminder)
/// each open `tangent.sqlite` themselves. With SQLite's default busy handler
/// (none), the second writer fails instantly with `database is locked
/// (code 5)` — on the Fold that surfaced as "Recording failed" the moment a
/// reminder task overlapped a sync push. `configureSqlite` is the one place
/// every connection gets its busy timeout, so this test drives it with two
/// raw connections on a temp file, exactly like two isolates would.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart' show configureSqlite;

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tangent-lock-');
    path = '${dir.path}${Platform.pathSeparator}db.sqlite';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a second connection waits out a held write lock instead of failing',
      () async {
    final Database a = sqlite3.open(path)
      ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    configureSqlite(a);
    final Database b = sqlite3.open(path);
    configureSqlite(b);
    addTearDown(() {
      a.dispose();
      b.dispose();
    });

    // Connection A holds a write transaction for 300 ms; B tries to write
    // meanwhile. Without a busy handler B throws code 5 immediately.
    a.execute('BEGIN IMMEDIATE');
    a.execute("INSERT INTO t (v) VALUES ('from a')");
    final Stopwatch clock = Stopwatch()..start();
    final Future<void> release = Future<void>.delayed(
      const Duration(milliseconds: 300),
      () => a.execute('COMMIT'),
    );

    // sqlite3's busy handler sleeps synchronously inside this call; the
    // COMMIT above runs from the event loop after it returns, so B's wait
    // must be bounded by busy_timeout, not by A's release, for this to be
    // a real test of the handler: assert B blocked (did not throw) and that
    // once A releases, B's write lands.
    Object? error;
    try {
      b.execute("INSERT INTO t (v) VALUES ('from b')");
    } catch (e) {
      error = e;
    }
    await release;
    if (error != null) {
      // B gave up only if it waited at least the configured timeout.
      expect(
        clock.elapsedMilliseconds,
        greaterThanOrEqualTo(4900),
        reason: 'a busy handler must wait, not fail instantly: $error',
      );
      b.execute("INSERT INTO t (v) VALUES ('from b')");
    }
    expect(
      b.select('SELECT count(*) AS n FROM t').first['n'],
      2,
      reason: 'both writers landed',
    );
  });

  test('configureSqlite turns on WAL and a 5 s busy timeout', () {
    final Database db = sqlite3.open(path);
    addTearDown(db.dispose);
    configureSqlite(db);
    expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
    expect(db.select('PRAGMA busy_timeout').first.values.first, 5000);
  });
}

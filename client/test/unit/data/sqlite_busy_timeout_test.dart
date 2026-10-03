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
import 'dart:isolate';

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
    a.close();

    // Another ISOLATE holds a write transaction for [holdMs] — exactly the
    // shape of the bug (a WorkManager isolate mid-write while the app
    // records). It must be a separate isolate: this one blocks inside
    // `b.execute` below, so a same-isolate holder could never release.
    //
    // Why the hold is SHORT (25 ms, not seconds): SQLite's default busy
    // handler sleeps in ~1-100 ms steps and counts the PLANNED sleep, not
    // wall time. Under flutter_tester (Dart JIT, sampling profiler on) on
    // Linux, SIGPROF interrupts every nanosleep after ~1 ms, so a 5000 ms
    // busy_timeout is exhausted after ~59 retries ≈ 60 ms of real time
    // (CI saw 64-310 ms; strace: `clock_nanosleep = ERESTART_RESTARTBLOCK`).
    // Windows Sleep() is not interruptible and release builds have no
    // profiler, so the app is fine — but the test may only rely on the
    // handler RETRYING, never on how long it keeps retrying.
    //
    // And the hold must be keyed to B ACTUALLY WAITING, not to a timer
    // started when the holder took the lock: between `held` and B's
    // `execute` sit an open + configureSqlite on B's side, and on a loaded
    // runner the holder's 25 ms timer fired late enough that B's ~60 ms
    // budget was already spent (v1.34.0's APK job: code 5 on a commit that
    // had passed CI minutes earlier). So B says "waiting" right before it
    // blocks, and only then does the holder start its short hold.
    final ReceivePort held = ReceivePort();
    final ReceivePort waiting = ReceivePort();
    final ReceivePort done = ReceivePort();
    final Isolate holder = await Isolate.spawn(
      _holdWriteLock,
      _HoldArgs(
        path,
        held.sendPort,
        waiting.sendPort,
        done.sendPort,
        holdMs: 10,
      ),
    );
    addTearDown(holder.kill);
    final SendPort release = await held.first as SendPort;

    final Database b = sqlite3.open(path);
    configureSqlite(b);
    addTearDown(b.close);
    final Stopwatch clock = Stopwatch()..start();
    release.send(null); // "about to block" — the holder's hold starts now
    // Without a busy handler this throws code 5 in well under a millisecond.
    SqliteException? budgetExhausted;
    try {
      b.execute("INSERT INTO t (v) VALUES ('from b')");
    } on SqliteException catch (e) {
      if (e.resultCode != 5) rethrow;
      budgetExhausted = e;
    }
    clock.stop();
    await done.first;

    if (budgetExhausted == null) {
      expect(
        clock.elapsedMilliseconds,
        greaterThanOrEqualTo(5),
        reason: 'B must have blocked on the held lock, not slipped past it',
      );
      expect(
        b.select('SELECT count(*) AS n FROM t').first['n'],
        2,
        reason: 'both writers landed',
      );
    } else {
      // Linux CI under flutter_tester: the ~60 ms real budget ran out
      // before the holder's release landed (port hop + timer on a loaded
      // runner — it happened on runs that had passed minutes earlier).
      // That is still the busy handler doing its job: it RETRIED for tens
      // of milliseconds before giving up. Without `PRAGMA busy_timeout`
      // the same statement throws code 5 in microseconds, so the elapsed
      // floor below is what separates "waited, then lost the race" from
      // "never waited" — the actual bug. 20 ms is well under the 64 ms
      // minimum CI has ever measured for an exhausted budget and well
      // over any single preemption of an instant throw.
      expect(
        clock.elapsedMilliseconds,
        greaterThanOrEqualTo(20),
        reason: 'code 5 after ${clock.elapsedMilliseconds} ms — the busy '
            'handler never retried: ${budgetExhausted.message}',
      );
    }
  });
  test('configureSqlite turns on WAL and a 5 s busy timeout', () {
    final Database db = sqlite3.open(path);
    addTearDown(db.close);
    configureSqlite(db);
    expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
    expect(db.select('PRAGMA busy_timeout').first.values.first, 5000);
  });
}

class _HoldArgs {
  const _HoldArgs(
    this.path,
    this.held,
    this.waiting,
    this.done, {
    required this.holdMs,
  });
  final String path;
  final SendPort held;
  final SendPort waiting;
  final SendPort done;
  final int holdMs;
}

/// Opens its own connection, takes the write lock, sends a port on [held],
/// waits for the test to say it is about to block on that port, keeps the
/// lock for [holdMs] more, commits, signals [done].
Future<void> _holdWriteLock(_HoldArgs args) async {
  final Database a = sqlite3.open(args.path);
  configureSqlite(a);
  a.execute('BEGIN IMMEDIATE');
  a.execute("INSERT INTO t (v) VALUES ('from a')");
  final ReceivePort release = ReceivePort();
  args.held.send(release.sendPort);
  await release.first;
  await Future<void>.delayed(Duration(milliseconds: args.holdMs));
  a.execute('COMMIT');
  a.close();
  args.done.send(null);
}

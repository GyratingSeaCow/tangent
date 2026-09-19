// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

/// The background sync isolate writes through its OWN database connection.
/// Drift stream watchers only observe writes made on their own connection,
/// so every notebook the background isolate pulls is invisible to the open
/// app until something forces a re-read — the "notebooks aren't syncing"
/// defect: the data was on the device, the screen never showed it.
void main() {
  late Directory dir;
  late LocalDb a;
  late LocalDb b;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tangent-external-writes');
    final File file = File('${dir.path}/db.sqlite');
    a = LocalDb.forTesting(NativeDatabase(file));
    b = LocalDb.forTesting(NativeDatabase(file));
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await dir.delete(recursive: true);
  });

  test(
      'refreshExternalWrites re-emits watchers with rows another connection '
      'wrote', () async {
    final StreamController<List<String>> seen =
        StreamController<List<String>>.broadcast();
    final StreamSubscription<List<String>> sub = (a.select(a.notebooks)
            .watch())
        .map((rows) => rows.map((r) => r.title).toList())
        .listen(seen.add);
    addTearDown(sub.cancel);

    expect(await seen.stream.first, isEmpty);

    // The "background isolate" lands a pulled notebook on its own connection.
    await b.applyRemoteNotebook(
      id: 'nb-external',
      title: 'pulled in the background',
      createdAt: 1,
      updatedAt: 2,
      docJson: '{}',
      inkJson: '{}',
      seq: 7,
    );

    // The refresh is what the app-resume hook calls: it must make every
    // watcher on THIS connection re-read and surface the external row.
    final Future<List<String>> after = seen.stream
        .firstWhere((titles) => titles.contains('pulled in the background'))
        .timeout(const Duration(seconds: 5));
    await a.refreshExternalWrites();
    expect(await after, contains('pulled in the background'));
  });
}

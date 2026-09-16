// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../../support/storage_fixture.dart';

void main() {
  test('watch search preserves escaped phrase ranking and 100 candidate cap',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    for (var i = 0; i < 102; i++) {
      final b = await f.seed('fixture-ranked-$i');
      await f.db.updateDumpTitle(
        b.key.dumpId,
        storageKey: b.key,
        title: 'ranked "phrase"',
        now: DateTime.utc(2030),
      );
    }
    final watched = await f.db.watchSearchDumps('ranked "phrase"').first;
    final queried = await f.db.searchDumps('ranked "phrase"', limit: 100);
    expect(watched, hasLength(100));
    expect(watched.map((r) => r.id), queried.map((r) => r.id));
    expect(
      await f.db.watchSearchDumps('ranked "phrase"', limit: 5).first,
      hasLength(5),
    );
  });

  test('same-query search emits title mutation without changing query',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-search');
    final stream = StreamIterator(f.db.watchSearchDumps('unique token'));
    addTearDown(stream.cancel);
    expect(await stream.moveNext(), isTrue);
    expect(stream.current, isEmpty);
    await f.db.updateDumpTitle(
      a.key.dumpId,
      storageKey: a.key,
      title: 'unique token',
      now: DateTime.utc(2030),
    );
    expect(await stream.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(stream.current.single.id, a.key.dumpId);
  });
}

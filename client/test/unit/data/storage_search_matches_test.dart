// SPDX-License-Identifier: AGPL-3.0-or-later
/// Search result evidence (spec §2 A1): alongside the ranked rows, each
/// hit carries an FTS5 snippet with the matched terms marked, a per-row
/// occurrence count on the transcript, and whether the title matched.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

import '../../support/storage_fixture.dart';

void main() {
  test('transcript hit: snippet marks the term and count is per-row', () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-hit-a', status: 'completed');
    await (f.db.update(f.db.dumps)..where((d) => d.id.equals(a.key.dumpId)))
        .write(
      const DumpsCompanion(
        transcript: Value(
          'We reviewed the budget today. The Budget is tight and the '
          'budget needs another look before Friday.',
        ),
      ),
    );
    final b = await f.seed('fixture-hit-b', status: 'completed');
    await (f.db.update(f.db.dumps)..where((d) => d.id.equals(b.key.dumpId)))
        .write(
      const DumpsCompanion(transcript: Value('No mention of money here.')),
    );

    final Map<String, DumpSearchMatch> matches =
        await f.db.watchSearchDumpMatches('budget').first;
    expect(matches.keys, [a.key.dumpId]);
    final m = matches[a.key.dumpId]!;
    expect(m.matchCount, 3);
    expect(m.titleMatched, isFalse);
    expect(m.snippet, contains('<b>budget</b>'));
    expect(m.snippet, contains('<b>Budget</b>'));
  });

  test('title hit: titleMatched is true and the snippet is the title',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-title', status: 'completed');
    await f.db.updateDumpTitle(
      a.key.dumpId,
      storageKey: a.key,
      title: 'Quarterly planning call',
      now: DateTime.utc(2030),
    );
    final matches = await f.db.watchSearchDumpMatches('planning').first;
    final m = matches[a.key.dumpId]!;
    expect(m.titleMatched, isTrue);
    expect(m.snippet, 'Quarterly <b>planning</b> call');
    expect(m.matchCount, 0, reason: 'the transcript has no occurrence');
  });

  test('empty query yields no matches', () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    await f.seed('fixture-empty', status: 'completed');
    expect(await f.db.watchSearchDumpMatches('   ').first, isEmpty);
  });
}

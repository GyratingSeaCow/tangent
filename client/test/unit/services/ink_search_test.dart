// SPDX-License-Identifier: AGPL-3.0-or-later
/// The ink search service, on an in-memory mirror of the server's ink_index.
///
/// The mirror arrives via sync (replace-set per notebook); this file seeds it
/// directly, because the service must be correct regardless of how rows got
/// there. Reading order, consecutive-word phrases and typed-block coverage
/// are the behaviours the find bar (Task 6) will lean on.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/ink_search.dart';

void main() {
  late LocalDb db;
  late InkSearch search;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    search = InkSearch(db);
  });

  tearDown(() async => db.close());

  /// Seeds one word row the way sync writes it: bbox as [l, t, r, b].
  Future<void> seedWord({
    required String notebook,
    required String line,
    required int slot,
    required String text,
    required List<double> bbox,
    List<String> strokes = const <String>['s-default'],
  }) async {
    await db.into(db.inkIndexEntries).insert(
          InkIndexEntriesCompanion.insert(
            id: '$notebook:$line:${slot.toString().padLeft(3, '0')}',
            notebookId: notebook,
            lineId: line,
            wordText: text,
            wordTextLower: text.toLowerCase(),
            bboxJson: jsonEncode(bbox),
            strokeIdsJson: jsonEncode(strokes),
            model: 'trocr-test',
            indexedAt: 1000,
          ),
        );
  }

  /// A notebook row whose doc carries typed blocks, so searchInNotebook can
  /// scan them alongside the ink index.
  Future<void> seedNotebook(
    String id,
    List<Map<String, dynamic>> blocks,
  ) async {
    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: id,
            title: 'Notebook $id',
            createdAt: 1,
            updatedAt: 2,
            docJson: jsonEncode({'blocks': blocks}),
            inkJson: '{}',
          ),
        );
  }

  group('searchInNotebook', () {
    test('a single-word query matches by substring and carries the row',
        () async {
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 0,
        text: 'Meeting',
        bbox: [10, 20, 90, 40],
        strokes: ['s1', 's2'],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 1,
        text: 'notes',
        bbox: [100, 20, 160, 40],
      );

      final matches = await search.searchInNotebook('nb-1', 'meet');

      expect(matches, hasLength(1));
      expect(matches.single.lineId, 'line-1');
      expect(matches.single.wordText, 'Meeting');
      expect(matches.single.strokeIds, ['s1', 's2']);
      expect(matches.single.bbox.left, 10);
      expect(matches.single.bbox.top, 20);
      expect(matches.single.bbox.right, 90);
      expect(matches.single.bbox.bottom, 40);
    });

    test('matching is case-insensitive in both directions', () async {
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 0,
        text: 'Groceries',
        bbox: [0, 0, 50, 10],
      );

      expect(await search.searchInNotebook('nb-1', 'GROC'), hasLength(1));
      expect(await search.searchInNotebook('nb-1', 'groc'), hasLength(1));
    });

    test('a multi-word query matches CONSECUTIVE words within one line',
        () async {
      // line-1 reads: "project kickoff meeting"
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 0,
        text: 'project',
        bbox: [0, 0, 50, 10],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 1,
        text: 'kickoff',
        bbox: [60, 0, 110, 10],
        strokes: ['k1'],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 2,
        text: 'meeting',
        bbox: [120, 0, 170, 10],
        strokes: ['m1'],
      );

      final matches = await search.searchInNotebook('nb-1', 'kickoff meeting');

      expect(matches, hasLength(1));
      expect(matches.single.wordText, 'kickoff meeting');
      expect(matches.single.lineId, 'line-1');
      // The phrase match unions the words' geometry and strokes: the find
      // bar highlights the whole phrase, not just its first word.
      expect(matches.single.bbox.left, 60);
      expect(matches.single.bbox.right, 170);
      expect(matches.single.strokeIds, ['k1', 'm1']);
    });

    test('non-consecutive words within a line do NOT match a phrase', () async {
      // line-1 reads: "project kickoff meeting" — "project meeting" skips a
      // word, so it is not the phrase the user wrote.
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 0,
        text: 'project',
        bbox: [0, 0, 50, 10],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 1,
        text: 'kickoff',
        bbox: [60, 0, 110, 10],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 2,
        text: 'meeting',
        bbox: [120, 0, 170, 10],
      );

      expect(
        await search.searchInNotebook('nb-1', 'project meeting'),
        isEmpty,
      );
    });

    test('a phrase does not straddle two lines', () async {
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 0,
        text: 'kickoff',
        bbox: [0, 0, 50, 10],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-2',
        slot: 0,
        text: 'meeting',
        bbox: [0, 20, 50, 30],
      );

      expect(
        await search.searchInNotebook('nb-1', 'kickoff meeting'),
        isEmpty,
      );
    });

    test('results come back in reading order: bbox top, then left', () async {
      // Deliberately seeded out of reading order.
      await seedWord(
        notebook: 'nb-1',
        line: 'line-low',
        slot: 0,
        text: 'xylophone',
        bbox: [10, 200, 60, 220],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-top-right',
        slot: 0,
        text: 'xenon',
        bbox: [300, 50, 350, 70],
      );
      await seedWord(
        notebook: 'nb-1',
        line: 'line-top-left',
        slot: 0,
        text: 'xerox',
        bbox: [20, 50, 70, 70],
      );

      final matches = await search.searchInNotebook('nb-1', 'x');

      expect(
        matches.map((m) => m.wordText).toList(),
        ['xerox', 'xenon', 'xylophone'],
        reason: 'reading order is top, then left',
      );
      expect(
        matches.map((m) => m.pageOrderKey).toList(),
        [0, 1, 2],
        reason: 'pageOrderKey walks the sorted order so next/prev is a ++',
      );
    });

    test('typed text and checkbox blocks match, with empty strokeIds',
        () async {
      await seedNotebook('nb-typed', [
        {
          'kind': 'text',
          'id': 'blk-1',
          'text': 'Buy milk today',
          'x': 12.0,
          'y': 34.0,
        },
        {
          'kind': 'checkbox',
          'id': 'blk-2',
          'text': 'call dentist',
          'checked': false,
          'x': 15.0,
          'y': 300.0,
        },
      ]);

      final milk = await search.searchInNotebook('nb-typed', 'milk');
      expect(milk, hasLength(1));
      expect(
        milk.single.strokeIds,
        isEmpty,
        reason: 'a typed block has no ink to highlight',
      );
      expect(milk.single.bbox.left, 12.0);
      expect(milk.single.bbox.top, 34.0);
      expect(
        milk.single.lineId,
        'blk-1',
        reason: 'the block id is the anchor the find bar scrolls to',
      );

      final dentist = await search.searchInNotebook('nb-typed', 'DENTIST');
      expect(dentist, hasLength(1));
      expect(dentist.single.strokeIds, isEmpty);
    });

    test('ink and typed matches interleave in reading order', () async {
      await seedNotebook('nb-mixed', [
        {
          'kind': 'text',
          'id': 'blk-1',
          'text': 'zebra crossing',
          'x': 5.0,
          'y': 10.0,
        },
      ]);
      await seedWord(
        notebook: 'nb-mixed',
        line: 'line-1',
        slot: 0,
        text: 'zebra',
        bbox: [5, 100, 60, 120],
      );

      final matches = await search.searchInNotebook('nb-mixed', 'zebra');

      expect(matches, hasLength(2));
      expect(
        matches.first.lineId,
        'blk-1',
        reason: 'the typed block sits above the ink line on the page',
      );
      expect(matches.last.lineId, 'line-1');
    });

    test('a blank query matches nothing', () async {
      await seedWord(
        notebook: 'nb-1',
        line: 'line-1',
        slot: 0,
        text: 'anything',
        bbox: [0, 0, 10, 10],
      );
      expect(await search.searchInNotebook('nb-1', '   '), isEmpty);
    });
  });

  group('searchNotebooks', () {
    test('summaries count matches per notebook and carry a line snippet',
        () async {
      // nb-a: two matches on one line that reads "team meeting notes".
      await seedWord(
        notebook: 'nb-a',
        line: 'line-1',
        slot: 0,
        text: 'team',
        bbox: [0, 0, 40, 10],
      );
      await seedWord(
        notebook: 'nb-a',
        line: 'line-1',
        slot: 1,
        text: 'meeting',
        bbox: [50, 0, 100, 10],
      );
      await seedWord(
        notebook: 'nb-a',
        line: 'line-2',
        slot: 0,
        text: 'meetings',
        bbox: [0, 20, 60, 30],
      );
      // nb-b: one match.
      await seedWord(
        notebook: 'nb-b',
        line: 'line-9',
        slot: 0,
        text: 'meet',
        bbox: [0, 0, 40, 10],
      );
      // nb-c: no match at all.
      await seedWord(
        notebook: 'nb-c',
        line: 'line-1',
        slot: 0,
        text: 'unrelated',
        bbox: [0, 0, 40, 10],
      );

      final summaries = await search.searchNotebooks('meet');

      expect(summaries.map((s) => s.notebookId).toSet(), {'nb-a', 'nb-b'});
      final nbA = summaries.firstWhere((s) => s.notebookId == 'nb-a');
      final nbB = summaries.firstWhere((s) => s.notebookId == 'nb-b');
      expect(nbA.matchCount, 2);
      expect(nbB.matchCount, 1);
      expect(
        nbA.snippet,
        'team meeting',
        reason: "the first matched line's words, joined in reading order",
      );
      expect(nbB.snippet, 'meet');
    });

    test('more matches sorts first', () async {
      await seedWord(
        notebook: 'nb-few',
        line: 'l1',
        slot: 0,
        text: 'query',
        bbox: [0, 0, 10, 10],
      );
      await seedWord(
        notebook: 'nb-many',
        line: 'l1',
        slot: 0,
        text: 'query',
        bbox: [0, 0, 10, 10],
      );
      await seedWord(
        notebook: 'nb-many',
        line: 'l2',
        slot: 0,
        text: 'query',
        bbox: [0, 20, 10, 30],
      );

      final summaries = await search.searchNotebooks('query');
      expect(summaries.first.notebookId, 'nb-many');
    });
  });
}

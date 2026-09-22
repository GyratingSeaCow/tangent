// SPDX-License-Identifier: AGPL-3.0-or-later
/// Task 6: the notebook find bar — Ctrl+F over handwriting.
///
/// The editor owns the match state (via InkSearch on the local db's ink
/// index mirror) and hands the canvas two stroke-id sets: every match, and
/// the CURRENT match, which must stay distinct — that distinction is the
/// only way the eye can follow next/prev across a page of hits. Reading
/// order comes from the service; these tests seed line ids whose STRING
/// order disagrees with their page order, so a lineId sort cannot pass.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/screens/settings/handwriting_search_section.dart'
    show handwritingSearchEnabledProvider;
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDb db;
  late FakeNotebookRepository repository;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  /// Seeds one indexed word the way sync writes it: bbox as [l, t, r, b].
  Future<void> seedWord({
    String notebook = 'nb-1',
    required String line,
    int slot = 0,
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

  /// A notebooks-table row whose doc carries typed blocks, so a typed match
  /// can be found (InkSearch reads the stored doc, not the editor's state).
  Future<void> seedNotebookRow(
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

  Future<void> mountEditor(
    WidgetTester tester, {
    required Notebook notebook,
    bool searchEnabled = true,
    String? initialFindQuery,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    repository = FakeNotebookRepository(seed: <Notebook>[notebook]);
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          notebookRepositoryProvider.overrideWithValue(repository),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
          localDbProvider.overrideWithValue(db),
          handwritingSearchEnabledProvider.overrideWith(
            (ref) => searchEnabled,
          ),
        ],
        child: MaterialApp(
          home: NotebookEditorScreen(
            notebookId: notebook.id,
            initialFindQuery: initialFindQuery,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  NotebookInkCanvas canvas(WidgetTester tester) =>
      tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

  String? position(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey<String>('notebook-find-position')))
      .data;

  /// A notebook whose ink carries the stroke ids the index rows reference,
  /// so the highlight painter has real geometry to band.
  Notebook inked() => testNotebook(
        id: 'nb-1',
        title: 'Field notes',
        strokes: <InkStroke>[
          for (final (String id, double y) in <(String, double)>[
            ('s1', 30),
            ('s2', 32),
            ('s3', 230),
            ('s4', 430),
            ('s9', 630),
          ])
            InkStroke(
              id: id,
              width: 3,
              points: <InkPoint>[InkPoint(x: 20, y: y), InkPoint(x: 80, y: y)],
            ),
        ],
      );

  /// Three matches for 'meet' whose line-id STRING order ('a-mid', 'm-low',
  /// 'z-top') disagrees with reading order (top, middle, low) — an
  /// implementation sorting by lineId fails the order walk below.
  Future<void> seedThreeMatches() async {
    await seedWord(
      line: 'z-top',
      text: 'meeting',
      bbox: <double>[10, 20, 90, 40],
      strokes: <String>['s1', 's2'],
    );
    await seedWord(
      line: 'a-mid',
      text: 'meetup',
      bbox: <double>[10, 220, 90, 240],
      strokes: <String>['s3'],
    );
    await seedWord(
      line: 'm-low',
      text: 'meet',
      bbox: <double>[10, 420, 90, 440],
      strokes: <String>['s4'],
    );
    // A word the query must NOT match: its strokes must never light up.
    await seedWord(
      line: 'noise',
      text: 'zebra',
      bbox: <double>[10, 620, 90, 640],
      strokes: <String>['s9'],
    );
  }

  testWidgets('typing a query highlights exactly the matched stroke ids',
      (tester) async {
    await seedThreeMatches();
    await mountEditor(tester, notebook: inked());

    // Ctrl+F lives behind the toolbar's search icon.
    await tester.tap(find.byKey(const ValueKey<String>('notebook-editor-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('notebook-find-field')),
      'meet',
    );
    await tester.pumpAndSettle();

    expect(
      canvas(tester).highlightedStrokeIds,
      <String>{'s1', 's2', 's3', 's4'},
      reason: 'every matched stroke lights up — and ONLY matched strokes '
          '(s9 belongs to an unmatched word)',
    );
    expect(
      canvas(tester).currentMatchStrokeIds,
      <String>{'s1', 's2'},
      reason: 'the current match is the FIRST in reading order, distinct '
          'from the full match set',
    );
    expect(position(tester), '1/3');

    await unmount(tester);
  });

  testWidgets('next and prev walk matches in reading order and wrap',
      (tester) async {
    await seedThreeMatches();
    await mountEditor(tester, notebook: inked());
    await tester.tap(find.byKey(const ValueKey<String>('notebook-editor-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('notebook-find-field')),
      'meet',
    );
    await tester.pumpAndSettle();
    expect(position(tester), '1/3');

    final Finder next = find.byKey(const ValueKey<String>('notebook-find-next'));
    final Finder prev = find.byKey(const ValueKey<String>('notebook-find-prev'));

    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(position(tester), '2/3');
    expect(
      canvas(tester).currentMatchStrokeIds,
      <String>{'s3'},
      reason: 'second in READING order is the middle line — not the second '
          'line id alphabetically',
    );

    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(position(tester), '3/3');
    expect(canvas(tester).currentMatchStrokeIds, <String>{'s4'});

    // Walk off the end: wraps to the first match.
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(position(tester), '1/3');
    expect(canvas(tester).currentMatchStrokeIds, <String>{'s1', 's2'});

    // And prev off the front wraps to the last.
    await tester.tap(prev);
    await tester.pumpAndSettle();
    expect(position(tester), '3/3');
    expect(canvas(tester).currentMatchStrokeIds, <String>{'s4'});

    // The full match set never changed while walking.
    expect(
      canvas(tester).highlightedStrokeIds,
      <String>{'s1', 's2', 's3', 's4'},
    );

    await unmount(tester);
  });

  testWidgets('close dismisses the bar and clears every highlight',
      (tester) async {
    await seedThreeMatches();
    await mountEditor(tester, notebook: inked());
    await tester.tap(find.byKey(const ValueKey<String>('notebook-editor-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('notebook-find-field')),
      'meet',
    );
    await tester.pumpAndSettle();
    expect(canvas(tester).highlightedStrokeIds, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('notebook-find-close')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('notebook-find-field')),
      findsNothing,
    );
    expect(canvas(tester).highlightedStrokeIds, isEmpty);
    expect(canvas(tester).currentMatchStrokeIds, isEmpty);

    await unmount(tester);
  });

  testWidgets('the search icon is absent entirely while the toggle is off',
      (tester) async {
    await mountEditor(tester, notebook: inked(), searchEnabled: false);

    expect(
      find.byKey(const ValueKey<String>('notebook-editor-search')),
      findsNothing,
      reason: 'while handwriting search is off, no OCR UI appears anywhere',
    );

    await unmount(tester);
  });

  testWidgets('a typed-block match scrolls to the block without ink highlight',
      (tester) async {
    // The match lives in a typed text block far down the page: the find bar
    // must scroll there, and must NOT light any ink (no strokes to light).
    await seedNotebookRow('nb-1', <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'text',
        'id': 'blk-1',
        'text': 'Buy milk today',
        'x': 12.0,
        'y': 2000.0,
      },
    ]);
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'blk-1', text: 'Buy milk today', x: 12, y: 2000),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('notebook-editor-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('notebook-find-field')),
      'milk',
    );
    await tester.pumpAndSettle();

    expect(position(tester), '1/1');
    expect(canvas(tester).highlightedStrokeIds, isEmpty);
    expect(canvas(tester).currentMatchStrokeIds, isEmpty);
    final SingleChildScrollView scroll = tester.widget(
      find.byKey(const ValueKey<String>('notebook-canvas-scroll')),
    );
    expect(
      scroll.controller!.offset,
      greaterThan(0),
      reason: 'the current match (y=2000) was scrolled into view',
    );

    await unmount(tester);
  });

  testWidgets(
      'initialFindQuery opens at the top result with the bar populated',
      (tester) async {
    await seedThreeMatches();
    await mountEditor(tester, notebook: inked(), initialFindQuery: 'meet');
    await tester.pumpAndSettle();

    final TextField field = tester.widget(
      find.byKey(const ValueKey<String>('notebook-find-field')),
    );
    expect(field.controller!.text, 'meet', reason: 'the bar arrives populated');
    expect(position(tester), '1/3', reason: 'the FIRST match is current');
    expect(canvas(tester).currentMatchStrokeIds, <String>{'s1', 's2'});

    // Next works normally from the deep link, exactly as if typed.
    await tester.tap(find.byKey(const ValueKey<String>('notebook-find-next')));
    await tester.pumpAndSettle();
    expect(position(tester), '2/3');
    expect(canvas(tester).currentMatchStrokeIds, <String>{'s3'});

    await unmount(tester);
  });
}

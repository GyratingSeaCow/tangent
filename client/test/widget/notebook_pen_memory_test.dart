// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-notebook pen memory (Jeff, 2026-09-23):
//
//   "Each notebook needs to remember what pens were last used during its
//    last session... I write my personal stuff in fountain pen and then
//    the other one I write in ballpoint so I need it to stick to the last
//    pen used."
//
// Contract:
//   1. A notebook whose stored lastPenStyle is ballpoint reopens with the
//      ballpoint nib selected — not the global fountain default.
//   2. Switching nibs marks the notebook dirty and the next save persists
//      the new nib on the notebook row.
//   3. A notebook that has never recorded a nib (lastPenStyle == null —
//      every notebook written before this feature) falls back to the
//      fountain default.
//
// Asserted through the mounted canvas widget and the repository's saved
// rows — the editor's real inputs and outputs, not private state.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

/// Routes saves straight to the repository: the durable-publication half
/// of the real [NotebookPersistence] needs a storage backend no widget
/// test has, and pen memory is proven on the repository row anyway.
class _RepoOnlyPersistence implements NotebookPersistence {
  _RepoOnlyPersistence(this._repository);

  final NotebookRepository _repository;

  @override
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await _repository.saveNotebook(notebook);
    return notebook;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<FakeNotebookRepository> _mount(
  WidgetTester tester, {
  PenStyle? lastPenStyle,
}) async {
  final FakeNotebookRepository repo = FakeNotebookRepository();
  Notebook notebook = await repo.createNotebook(title: 'Pen memory');
  if (lastPenStyle != null) {
    notebook = notebook.copyWith(lastPenStyle: lastPenStyle);
    await repo.saveNotebook(notebook);
    repo.saved.clear();
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notebookRepositoryProvider.overrideWithValue(repo),
        notebookPersistenceProvider.overrideWithValue(
          _RepoOnlyPersistence(repo),
        ),
      ],
      child: MaterialApp(
        home: NotebookEditorScreen(notebookId: notebook.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

NotebookInkCanvas _canvas(WidgetTester tester) =>
    tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

void main() {
  testWidgets('a notebook last written in ballpoint reopens in ballpoint',
      (WidgetTester tester) async {
    await _mount(tester, lastPenStyle: PenStyle.ballpoint);
    expect(
      _canvas(tester).penStyle,
      PenStyle.ballpoint,
      reason: 'the notebook remembers ITS pen, not the global default',
    );
  });

  testWidgets('a notebook last written in fountain reopens in fountain',
      (WidgetTester tester) async {
    await _mount(tester, lastPenStyle: PenStyle.fountain);
    expect(_canvas(tester).penStyle, PenStyle.fountain);
  });

  testWidgets(
      'a notebook that never recorded a nib opens with the '
      'fountain default', (WidgetTester tester) async {
    await _mount(tester);
    expect(
      _canvas(tester).penStyle,
      PenStyle.fountain,
      reason: 'null lastPenStyle (pre-feature notebooks) reads as fountain',
    );
  });

  testWidgets('switching nibs persists on the next save',
      (WidgetTester tester) async {
    final FakeNotebookRepository repo =
        await _mount(tester, lastPenStyle: PenStyle.fountain);

    // The nib toggle flips fountain <-> ballpoint.
    await tester.tap(
      find.byKey(const ValueKey('notebook-pen-style')),
    );
    await tester.pumpAndSettle();
    expect(_canvas(tester).penStyle, PenStyle.ballpoint);

    // The switch alone marked the notebook dirty: leaving the screen
    // saves (the editor's PopScope turns back-navigation into save-then-
    // pop). Drive the system back like Android would.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      repo.saved,
      isNotEmpty,
      reason: 'a nib switch is a change worth saving',
    );
    expect(
      repo.saved.last.lastPenStyle,
      PenStyle.ballpoint,
      reason: 'the saved row carries the nib for the next open',
    );
  });
}

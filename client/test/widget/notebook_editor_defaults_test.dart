// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Notebook editor DEFAULTS (Jeff's contract, 2026-09-22):
//
// 1. The pen defaults to the FOUNTAIN nib. The ballpoint was the original
//    style and stayed the default only by seniority; the fountain pen is
//    the one actually used.
// 2. Draw mode starts OFF. With draw OFF a finger DRAGS the page and a
//    stylus still inks (that contract is pinned separately in
//    notebook_pen_writes_without_mode_test.dart) — so a fresh notebook
//    must never open with the finger inking.
//
// These are asserted through the mounted canvas widget — the editor's
// actual output — not by reflecting on private state.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

Future<void> _mount(WidgetTester tester) async {
  final FakeNotebookRepository repo = FakeNotebookRepository();
  final Notebook notebook = await repo.createNotebook(title: 'Defaults');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notebookRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: NotebookEditorScreen(notebookId: notebook.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

NotebookInkCanvas _canvas(WidgetTester tester) =>
    tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

void main() {
  testWidgets('a fresh editor defaults to the fountain nib',
      (WidgetTester tester) async {
    await _mount(tester);
    expect(
      _canvas(tester).penStyle,
      PenStyle.fountain,
      reason: 'the fountain pen is the default nib, not ballpoint',
    );
  });

  testWidgets('a fresh editor opens with draw mode OFF '
      '(finger drags the page; only the stylus inks)',
      (WidgetTester tester) async {
    await _mount(tester);
    expect(
      _canvas(tester).drawingEnabled,
      isFalse,
      reason: 'draw mode must start off so a finger scrolls, never inks',
    );
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// Instrument Console v2 — the notebook editor adopts the shared chrome
/// (nav rail with Notebooks lit, NO global create key: the stylus canvas
/// needs the space) and its tool strip gets the rail's visual language:
/// the active tool sits on a quiet tinted pill with the signal icon,
/// inactive tools stay dim. Styling only — tool switching, canvas and ink
/// behaviour are untouched (and pinned by their own tests).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/instrument_scaffold.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

import '../support/fake_notebook_repository.dart';

Future<void> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeNotebookRepository repo = FakeNotebookRepository();
  final Notebook notebook = await repo.createNotebook(title: 'Console');
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

/// The decoration of a tool's pill wrapper, or null when undecorated.
BoxDecoration? _pillDecoration(WidgetTester tester, String tool) {
  final Container pill = tester.widget<Container>(
    find.byKey(ValueKey<String>('tool-pill-$tool')),
  );
  return pill.decoration as BoxDecoration?;
}

void main() {
  testWidgets(
      'the editor sits under the nav rail with Notebooks lit and suppresses '
      'the global create key for stylus space', (tester) async {
    await _mount(tester);

    for (final TangentRoot root in TangentRoot.values) {
      expect(find.byKey(railKey(root)), findsOneWidget);
    }
    final IconButton notebooks = tester.widget<IconButton>(
      find.byKey(railKey(TangentRoot.notebooks)),
    );
    expect(
      notebooks.onPressed,
      isNull,
      reason: 'the active destination is a no-op',
    );
    expect(notebooks.disabledColor, TangentColors.signal);

    expect(
      find.byKey(InstrumentScaffold.createFabKey),
      findsNothing,
      reason: 'the stylus canvas keeps the corner: no create key here',
    );
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets(
      'the active tool wears the tinted pill with the signal icon; inactive '
      'tools stay dim and undecorated', (tester) async {
    await _mount(tester);

    // Cold start: draw mode off, no drawing tool is active — no pills.
    // (The nib is a STYLE toggle, not a mode, and keeps its own selected
    // state: fountain is the default, so its pill is lit from the start.)
    expect(_pillDecoration(tester, 'pen'), isNull);
    expect(_pillDecoration(tester, 'highlighter'), isNull);
    expect(_pillDecoration(tester, 'eraser'), isNull);
    expect(_pillDecoration(tester, 'lasso'), isNull);
    expect(
      _pillDecoration(tester, 'nib'),
      isNotNull,
      reason: 'fountain is the default nib, shown selected',
    );

    // Tap Draw: the pen is the active tool — tinted pill, panel radius.
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    final BoxDecoration pen = _pillDecoration(tester, 'pen')!;
    expect(
      pen.color,
      TopNavRail.activeTint,
      reason: 'same quiet pill the rail uses for its active destination',
    );
    expect(
      pen.borderRadius,
      BorderRadius.circular(TangentShapes.panelRadius),
    );
    expect(_pillDecoration(tester, 'highlighter'), isNull);

    // The highlighter takes over: its pill lights, the pen goes dark.
    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();
    expect(_pillDecoration(tester, 'highlighter'), isNotNull);
    expect(_pillDecoration(tester, 'pen'), isNull);

    // Lasso from any state: its pill lights.
    await tester.tap(find.byKey(const ValueKey('notebook-lasso')));
    await tester.pump();
    expect(_pillDecoration(tester, 'lasso'), isNotNull);
  });

  testWidgets('mode tools carry pill wrappers; the undo/redo pair stays plain',
      (tester) async {
    await _mount(tester);

    // Every MODE tool has a pill wrapper (lit or not). Icon colours are
    // deliberately NOT restyled: the pen and highlighter icons carry the
    // picked INK colour, which is load-bearing, and the rest inherit the
    // theme's dim foreground.
    for (final String tool in <String>[
      'pen',
      'highlighter',
      'eraser',
      'nib',
      'lasso',
    ]) {
      expect(
        find.byKey(ValueKey<String>('tool-pill-$tool')),
        findsOneWidget,
      );
    }

    // Undo/redo are actions, not modes: no pill wrapper at all.
    expect(find.byKey(const ValueKey<String>('tool-pill-undo')), findsNothing);
    expect(find.byKey(const ValueKey<String>('tool-pill-redo')), findsNothing);
  });
}

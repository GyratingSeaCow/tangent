// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/dump.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/dump_picker_sheet.dart';
import 'package:tangent/widgets/notebook_dump_card.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

/// T4: the notebook editor — text/checkbox blocks over a draggable dump-card
/// layer under an ink canvas, a page-local pen toolbar, and an explicit save.

DumpRow _dumpRow(String id, String title, {String mode = 'brain_dump'}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 17, 8),
      updatedAt: DateTime.utc(2026, 9, 17, 8),
      mode: mode,
      durationSeconds: mode == 'text_note' ? 0 : 95,
      title: title,
      audioPath: '/audio/$id.m4a',
      audioSizeBytes: 2048,
      syncStatus: 'local_only',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );

/// Records notebooks handed to the durable-publication path so a test can
/// prove Save went through NotebookPersistence and not just the repository.
class _RecordingNotebookPersistence implements NotebookPersistence {
  _RecordingNotebookPersistence(this._repository, this.published);

  final NotebookRepository _repository;
  final List<Notebook> published;

  @override
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await _repository.saveNotebook(notebook);
    published.add(notebook);
    return notebook;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookRepository repository;
  final List<Notebook> publishedNotebooks = <Notebook>[];
  setUp(publishedNotebooks.clear);

  /// Mounts a host route and pushes the editor onto it, so the app-bar back
  /// button (and therefore the unsaved-changes guard) behaves as it does in
  /// the real app.
  Future<void> mountEditor(
    WidgetTester tester, {
    required Notebook notebook,
    List<DumpRow> dumps = const <DumpRow>[],
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
          notebookPersistenceProvider.overrideWithValue(
            _RecordingNotebookPersistence(repository, publishedNotebooks),
          ),
          dumpsProvider.overrideWith((_) => Stream<List<DumpRow>>.value(dumps)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          NotebookEditorScreen(notebookId: notebook.id),
                    ),
                  ),
                  child: const Text('open notebook'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open notebook'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Finder textBlocks() => find.byWidgetPredicate(
        (Widget widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>)
                .value
                .startsWith('notebook-text-block-'),
      );

  Finder checkboxBlocks() => find.byWidgetPredicate(
        (Widget widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>)
                .value
                .startsWith('notebook-checkbox-block-'),
      );

  bool anyFieldFocused(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .any((EditableText field) => field.focusNode.hasFocus);

  Notebook seeded() => testNotebook(
        id: 'nb-1',
        title: 'Sprint ideas',
        blocks: <NotebookBlock>[
          const NotebookTextBlock(id: 'b1', text: 'hello notebook'),
          const NotebookCheckboxBlock(id: 'b2', text: 'milk', checked: true),
          const NotebookDumpCardBlock(id: 'b3', dumpId: 'd1', x: 24, y: 120),
        ],
      );

  testWidgets('renders text, checkbox and dump-card blocks from storage',
      (tester) async {
    await mountEditor(
      tester,
      notebook: seeded(),
      dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
    );

    expect(find.text('Sprint ideas'), findsOneWidget);
    expect(find.text('hello notebook'), findsOneWidget);
    expect(find.text('milk'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isTrue,
      reason: 'a checked checkbox block round trips its state',
    );
    expect(find.byType(NotebookDumpCard), findsOneWidget);
    expect(find.text('Morning ideas'), findsOneWidget);
    expect(find.byType(NotebookInkCanvas), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('a dump-card block whose dump is gone renders unavailable',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookDumpCardBlock(id: 'b3', dumpId: 'deleted-dump', x: 10, y: 40),
        ],
      ),
      dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
    );

    expect(find.byType(NotebookDumpCard), findsOneWidget);
    expect(find.text('Recording unavailable'), findsOneWidget);
    expect(
      tester.widget<NotebookDumpCard>(find.byType(NotebookDumpCard)).dump,
      isNull,
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets(
      'draw mode reveals the page pen toolbar and blocks text interaction',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    expect(find.byType(PenSizeControl), findsNothing);
    expect(find.byIcon(Icons.undo), findsNothing);
    expect(
      tester
          .widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas))
          .drawingEnabled,
      isFalse,
    );

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();

    expect(find.byType(PenSizeControl), findsOneWidget);
    expect(find.byIcon(Icons.undo), findsOneWidget);
    expect(
      tester
          .widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas))
          .drawingEnabled,
      isTrue,
    );

    await tester.tap(textBlocks().first, warnIfMissed: false);
    await tester.pump();
    expect(
      anyFieldFocused(tester),
      isFalse,
      reason: 'the ink layer owns the pointer while draw mode is on',
    );

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    expect(find.byType(PenSizeControl), findsNothing);

    await tester.tap(textBlocks().first);
    await tester.pump();
    expect(
      anyFieldFocused(tester),
      isTrue,
      reason: 'leaving draw mode restores normal text editing',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('Save publishes the durable file, not just the database row',
      (tester) async {
    // Regression: the editor called notebookRepositoryProvider (database only)
    // instead of notebookPersistenceProvider, so notebooks never reached
    // 'Tangent Notebooks' on disk and an uninstall would lose them. Caught on
    // the device: the row saved, the folder was never created.
    await mountEditor(tester, notebook: seeded());

    await tester.enterText(textBlocks().first, 'durable body');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      publishedNotebooks,
      hasLength(1),
      reason: 'Save must route through NotebookPersistence so the '
          '<id>.notebook.json file is published.',
    );
    expect(publishedNotebooks.single.id, 'nb-1');
    expect(
      publishedNotebooks.single.document.blocks
          .whereType<NotebookTextBlock>()
          .single
          .text,
      'durable body',
    );
  });

  testWidgets('Save writes the edited title, text and checkbox state',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    await tester.enterText(
      find.byKey(const ValueKey('notebook-title-field')),
      'Renamed notebook',
    );
    await tester.enterText(textBlocks().first, 'edited body');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    expect(repository.saved, isEmpty);

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repository.saved, hasLength(1));
    final Notebook written = repository.saved.single;
    expect(written.id, 'nb-1');
    expect(written.title, 'Renamed notebook');
    expect(
      written.document.blocks.whereType<NotebookTextBlock>().single.text,
      'edited body',
    );
    expect(
      written.document.blocks.whereType<NotebookCheckboxBlock>().single.checked,
      isFalse,
    );
    expect(
      written.document.blocks.whereType<NotebookDumpCardBlock>().single.dumpId,
      'd1',
      reason: 'a dump-card block survives a save untouched',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('the insert menu appends new text and checkbox blocks',
      (tester) async {
    // Drives the bottom-left insert menu that replaced the button row; the
    // assertions below are unchanged from when those buttons existed.
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    expect(textBlocks(), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text block'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checkbox'));
    await tester.pumpAndSettle();

    expect(textBlocks(), findsOneWidget);
    expect(checkboxBlocks(), findsOneWidget);

    await tester.enterText(textBlocks().first, 'brand new');
    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final List<NotebookBlock> blocks = repository.saved.single.document.blocks;
    expect(blocks, hasLength(2));
    expect(blocks.whereType<NotebookTextBlock>().single.text, 'brand new');
    expect(blocks.whereType<NotebookCheckboxBlock>(), hasLength(1));
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('Add recordings embeds the picked dumps as cards',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookDumpCardBlock(id: 'b1', dumpId: 'd1', x: 0, y: 0),
        ],
      ),
      dumps: <DumpRow>[
        _dumpRow('d1', 'Morning ideas'),
        _dumpRow('d2', 'Standup notes'),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dump'));
    await tester.pumpAndSettle();

    expect(find.byType(DumpPickerSheet), findsOneWidget);
    expect(
      tester
          .widget<DumpPickerSheet>(find.byType(DumpPickerSheet))
          .initiallySelected,
      <String>{'d1'},
      reason: 'already-embedded recordings start checked',
    );

    await tester.tap(find.byKey(const ValueKey('dump-pick-d2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(NotebookDumpCard), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final List<NotebookDumpCardBlock> cards = repository
        .saved.single.document.blocks
        .whereType<NotebookDumpCardBlock>()
        .toList();
    expect(cards.map((NotebookDumpCardBlock c) => c.dumpId), <String>[
      'd1',
      'd2',
    ]);
    expect(
      Offset(cards[1].x, cards[1].y),
      isNot(Offset(cards[0].x, cards[0].y)),
      reason: 'a new card must not land exactly on an existing one',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets(
    'the insert menu opens from the bottom-left and offers every insert',
    (tester) async {
      // Jeff asked for one burger-style menu in the bottom-left corner
      // holding the insert actions, instead of a row of buttons.
      await mountEditor(
        tester,
        notebook: testNotebook(id: 'nb-1'),
        dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
      );

      expect(
        find.byKey(const ValueKey('notebook-insert-menu')),
        findsOneWidget,
        reason: 'the insert menu must be reachable from the editor',
      );
      // The old always-on row is gone: the menu replaces it.
      expect(find.text('Add checkbox'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
      await tester.pumpAndSettle();

      for (final String label in <String>[
        'Text block',
        'Checkbox',
        'Dump',
        'Meeting notes',
        'Text note',
      ]) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: '"$label" must be offered in the insert menu',
        );
      }

      await unmount(tester);
    },
  );

  testWidgets('importing a text note offers only text notes', (tester) async {
    // Picking "Text note" must not make Jeff scroll past 60 recordings to
    // find the notes: each import entry filters the picker to its own kind.
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1'),
      dumps: <DumpRow>[
        _dumpRow('d1', 'Morning ideas'),
        _dumpRow('m1', 'Standup', mode: 'meeting'),
        _dumpRow('t1', 'Shopping list', mode: 'text_note'),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text note'));
    await tester.pumpAndSettle();

    expect(find.byType(DumpPickerSheet), findsOneWidget);
    final DumpPickerSheet sheet =
        tester.widget<DumpPickerSheet>(find.byType(DumpPickerSheet));
    expect(
      sheet.dumps.map((Dump d) => d.id).toList(),
      <String>['t1'],
      reason: 'the text-note import must offer text notes only',
    );
    // A sheet full of text notes headed "Add recordings" reads as the wrong
    // list having opened.
    expect(
      find.text('Add text notes'),
      findsOneWidget,
      reason: 'the sheet must name the kind it is actually offering',
    );

    await unmount(tester);
  });

  testWidgets('importing a meeting embeds it as a card', (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1'),
      dumps: <DumpRow>[
        _dumpRow('d1', 'Morning ideas'),
        _dumpRow('m1', 'Standup', mode: 'meeting'),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meeting notes'));
    await tester.pumpAndSettle();

    final DumpPickerSheet sheet =
        tester.widget<DumpPickerSheet>(find.byType(DumpPickerSheet));
    expect(
      sheet.dumps.map((Dump d) => d.id).toList(),
      <String>['m1'],
      reason: 'the meeting import must offer meetings only',
    );

    await tester.tap(find.byKey(const ValueKey('dump-pick-m1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
    await tester.pumpAndSettle();

    expect(
      find.byType(NotebookDumpCard),
      findsOneWidget,
      reason: 'an imported meeting lands as a draggable card',
    );

    await unmount(tester);
  });

  testWidgets('the insert menu still adds text and checkbox blocks',
      (tester) async {
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checkbox'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('saving after editing blocks keeps existing ink', (tester) async {
    // Device evidence: a notebook saved with 2 strokes, then a later save
    // wrote strokes=0. Ink loss is a data-safety bug, so pin the exact
    // sequence: open a notebook that HAS ink, change only blocks, save.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'keep', x: 20, y: 40),
        ],
        strokes: <InkStroke>[
          const InkStroke(
            id: 's1',
            points: <InkPoint>[InkPoint(x: 10, y: 10), InkPoint(x: 40, y: 40)],
            width: 3,
          ),
        ],
      ),
    );

    // Touch only the blocks.
    await tester.enterText(
      find.byKey(const ValueKey('notebook-text-block-b1')),
      'edited',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      repository.saved.single.ink.strokes,
      hasLength(1),
      reason: 'editing text must never drop handwriting already on the page',
    );

    await unmount(tester);
  });

  testWidgets('a block\'s remove button is on screen, not off the page edge',
      (tester) async {
    // Jeff: "there is no way to delete the imported list items etc".
    // The X existed but sat at the far edge of a 720px-wide row on a ~400px
    // screen, so it was rendered off the visible page entirely.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'delete me', x: 20, y: 40),
        ],
      ),
    );

    final Finder remove = find.byKey(const ValueKey('notebook-block-remove-b1'));
    expect(remove, findsOneWidget, reason: 'every block needs a remove button');

    final Rect rect = tester.getRect(remove);
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      rect.right,
      lessThanOrEqualTo(screen.width),
      reason: 'the X must be on screen, got $rect on a $screen viewport',
    );

    await unmount(tester);
  });

  testWidgets('tapping a block\'s remove button deletes that block',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'delete me', x: 20, y: 40),
          NotebookTextBlock(id: 'b2', text: 'keep me', x: 20, y: 160),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-block-remove-b1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notebook-block-b1')), findsNothing);
    expect(find.byKey(const ValueKey('notebook-block-b2')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('backspace on an empty line deletes that line', (tester) async {
    // Jeff: "I want it so that when you tap backspace when there's nothing
    // left in the line, that it deletes the line item that you are currently
    // on."
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'first', x: 20, y: 40),
          NotebookCheckboxBlock(id: 'b2', text: '', x: 20, y: 160),
        ],
      ),
    );

    // Focus the empty checkbox line, then press backspace.
    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b2')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-block-b2')),
      findsNothing,
      reason: 'backspace on an empty line must delete the line',
    );
    expect(
      find.byKey(const ValueKey('notebook-block-b1')),
      findsOneWidget,
      reason: 'other lines must survive',
    );

    await unmount(tester);
  });

  testWidgets('enter on a checkbox line starts the next checkbox item',
      (tester) async {
    // Jeff: "when you are in the text area of a checkbox item, you can hit
    // enter and it will go into another checkbox list item, not expand the
    // box."
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'b1', text: 'milk', x: 20, y: 40),
        ],
      ),
    );

    expect(checkboxBlocks(), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b1')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      checkboxBlocks(),
      findsNWidgets(2),
      reason: 'enter must start a new checkbox item, not grow the field',
    );
    // The original line keeps its text: enter splits nothing, it appends.
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('notebook-checkbox-block-b1')),
          )
          .controller!
          .text,
      'milk',
      reason: 'the line being left must keep its own text',
    );
  });

  testWidgets('the new checkbox item is inserted directly after its source',
      (tester) async {
    // Appending to the end of the document would scatter a list being typed
    // top-to-bottom, so the new item must land next to the one it came from.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'b1', text: 'milk', x: 20, y: 40),
          NotebookTextBlock(id: 'b2', text: 'trailing note', x: 20, y: 160),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b1')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // Assert on what is RENDERED, in layout order: the new item must sit
    // between its source and the block that followed it. Match Positioned
    // exactly — 'notebook-block-grip-' and '-remove-' share the prefix.
    final RegExp blockKey = RegExp(r'^notebook-block-[^-]');
    final List<String> keysInOrder = tester
        .widgetList<Positioned>(
          find.byWidgetPredicate(
            (Widget w) =>
                w is Positioned &&
                w.key is ValueKey<String> &&
                blockKey.hasMatch((w.key! as ValueKey<String>).value),
          ),
        )
        .map((Positioned w) => (w.key! as ValueKey<String>).value)
        .toList();

    expect(
      keysInOrder.first,
      'notebook-block-b1',
      reason: 'the source item stays first',
    );
    expect(
      keysInOrder.last,
      'notebook-block-b2',
      reason: 'the following text block stays last, so the new item is between',
    );
    expect(
      keysInOrder.length,
      3,
      reason: 'exactly one new block was inserted',
    );
  });

  testWidgets('the soft keyboard enter key starts the next checkbox item',
      (tester) async {
    // The hardware-key test above passed while the DEVICE still grew the box:
    // an on-screen keyboard does not send key events at all. It commits text
    // and sends an EDITING ACTION through the text-input channel, so a fix
    // hung only off KeyDownEvent is dead for every user without a physical
    // keyboard — which on a tablet is all of them.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'b1', text: 'milk', x: 20, y: 40),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b1')));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(
      checkboxBlocks(),
      findsNWidgets(2),
      reason: 'the on-screen enter key must start a new checkbox item',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('notebook-checkbox-block-b1')),
          )
          .controller!
          .text,
      'milk',
      reason: 'the line being left must keep its own text',
    );
  });

  testWidgets('the checkbox field asks Android for an action key, not a newline',
      (tester) async {
    // Android IGNORES the IME action whenever the input type carries the
    // multi-line flag: it shows a newline key instead, the newline is
    // committed directly into the value, and performAction never fires. So
    // the field must declare a single-line INPUT TYPE (it still wraps, which
    // is maxLines' job) together with an explicit action.
    //
    // A widget test cannot host a real IME, so this pins the configuration
    // that makes the device behave. It is the half the harness can prove;
    // the other half is verified on hardware.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'b1', text: 'milk', x: 20, y: 40),
        ],
      ),
    );

    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey('notebook-checkbox-block-b1')),
    );

    expect(
      field.keyboardType,
      TextInputType.text,
      reason: 'a multiline input type makes Android ignore the action key',
    );
    expect(
      field.textInputAction,
      TextInputAction.next,
      reason: 'the enter key must deliver an action, not insert a newline',
    );
    expect(
      field.maxLines,
      isNull,
      reason: 'a long item must still wrap rather than scroll sideways',
    );
  });

  testWidgets('a prose block keeps the multiline keyboard and its newlines',
      (tester) async {
    // The counterpart to the rule above: prose is meant to take newlines, so
    // it must keep the multi-line input type and must NOT declare an action.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'para', x: 20, y: 40),
        ],
      ),
    );

    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey('notebook-text-block-b1')),
    );

    expect(
      field.keyboardType,
      anyOf(isNull, TextInputType.multiline),
      reason: 'prose keeps the multiline keyboard',
    );
    expect(
      field.textInputAction,
      isNull,
      reason: 'prose must keep taking newlines from the enter key',
    );
  });

  testWidgets('a soft-keyboard action on a prose line never spawns a checkbox',
      (tester) async {
    // Some IMEs send an action even to a multiline field. Prose must ignore
    // it rather than converting the paragraph into a list.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'para', x: 20, y: 40),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-text-block-b1')));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(
      checkboxBlocks(),
      findsNothing,
      reason: 'a text block must never spawn a checkbox',
    );
    expect(
      find.byKey(const ValueKey('notebook-block-b1')),
      findsOneWidget,
      reason: 'the text block must survive',
    );
  });

  testWidgets('a soft-keyboard action on an empty checkbox ends the list',
      (tester) async {
    // The escape hatch must work from the on-screen keyboard too, or there is
    // no way to stop adding items without a physical keyboard.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'b1', text: 'milk', x: 20, y: 40),
          NotebookCheckboxBlock(id: 'b2', text: '', x: 20, y: 160),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b2')));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(
      checkboxBlocks(),
      findsOneWidget,
      reason: 'an action on a blank item must end the list, not extend it',
    );
    expect(
      find.byKey(const ValueKey('notebook-block-b1')),
      findsOneWidget,
      reason: 'the filled item above must survive',
    );
  });

  testWidgets('enter on a plain text line still inserts a newline',
      (tester) async {
    // The checkbox behaviour must not leak into ordinary prose blocks, where
    // a multi-line paragraph is the whole point.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'para', x: 20, y: 40),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-text-block-b1')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      checkboxBlocks(),
      findsNothing,
      reason: 'a text block must never spawn a checkbox on enter',
    );
    expect(
      find.byKey(const ValueKey('notebook-block-b1')),
      findsOneWidget,
      reason: 'the text block must survive and keep taking newlines',
    );
  });

  testWidgets('enter on an empty checkbox item ends the list instead',
      (tester) async {
    // Standard list behaviour everywhere else: enter on a blank item exits
    // the list rather than producing an endless run of empty checkboxes.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'b1', text: 'milk', x: 20, y: 40),
          NotebookCheckboxBlock(id: 'b2', text: '', x: 20, y: 160),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b2')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      checkboxBlocks(),
      findsOneWidget,
      reason: 'enter on a blank item must end the list, not extend it',
    );
    expect(
      find.byKey(const ValueKey('notebook-block-b1')),
      findsOneWidget,
      reason: 'the filled item above must survive',
    );
  });

  testWidgets('backspace with text on the line only deletes a character',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'abc', x: 20, y: 40),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('notebook-text-block-b1')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notebook-block-b1')),
      findsOneWidget,
      reason: 'a line with text must not be deleted by backspace',
    );

    await unmount(tester);
  });

  testWidgets('the page scrolls vertically and never pinch-zooms',
      (tester) async {
    // Jeff, after using the pinch/drag canvas: "Make it more like the
    // infinite scrollable screen on samsung notes rather than the pinch and
    // drag since the pinch and drag seems to be interfering with the pen
    // eraser/writer." No InteractiveViewer at all: an endless vertical roll,
    // so nothing competes with the pen for the gesture.
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    expect(
      find.byType(InteractiveViewer),
      findsNothing,
      reason: 'pinch/pan fights the pen; the page is a vertical scroll',
    );
    expect(
      find.byKey(const ValueKey('notebook-canvas-scroll')),
      findsOneWidget,
      reason: 'the page must scroll vertically',
    );

    await unmount(tester);
  });

  testWidgets('drawing locks the page scroll so the pen never pans it',
      (tester) async {
    // A scrollable still steals a vertical drag from the ink layer, which is
    // exactly the interference Jeff reported. While drawing, the page holds.
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    ScrollPhysics? physics() => tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('notebook-canvas-scroll')),
        )
        .physics;

    expect(
      physics(),
      isNot(isA<NeverScrollableScrollPhysics>()),
      reason: 'with the pen up the page scrolls normally',
    );

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();

    expect(
      physics(),
      isA<NeverScrollableScrollPhysics>(),
      reason: 'in draw mode the finger inks and the page must not scroll',
    );

    await unmount(tester);
  });

  testWidgets('the page grows downward as content is placed lower',
      (tester) async {
    // "Infinite" in the Samsung Notes sense: the roll extends past whatever
    // you have written so there is always fresh page below.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'low', x: 20, y: 4000),
        ],
      ),
    );

    final double height = tester
        .getRect(find.byKey(const ValueKey('notebook-canvas-surface')))
        .height;

    expect(
      height,
      greaterThan(4000),
      reason: 'the page must extend past its lowest content, got $height',
    );

    await unmount(tester);
  });

  testWidgets('text blocks are draggable by their grip handle', (tester) async {
    // Jeff: "the text boxes need to be movable just like the audio boxes".
    // The grip is a separate handle so dragging never fights placing the
    // text cursor.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'movable', x: 40, y: 120),
        ],
      ),
    );

    final Finder grip = find.byKey(const ValueKey('notebook-block-grip-b1'));
    expect(grip, findsOneWidget, reason: 'each block needs a drag handle');


    await tester.drag(grip, const Offset(60, 90));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookTextBlock moved = repository.saved.single.document.blocks
        .whereType<NotebookTextBlock>()
        .single;
    expect(moved.x, closeTo(100, 0.5));
    expect(moved.y, closeTo(210, 0.5));

    await unmount(tester);
  });

  testWidgets('a block written before blocks were movable still opens',
      (tester) async {
    // Older notebooks have no x/y. They must lay out in order, not collapse
    // onto the same spot or vanish.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'first'),
          NotebookTextBlock(id: 'b2', text: 'second'),
        ],
      ),
    );

    final Rect first =
        tester.getRect(find.byKey(const ValueKey('notebook-block-b1')));
    final Rect second =
        tester.getRect(find.byKey(const ValueKey('notebook-block-b2')));

    expect(
      second.top,
      greaterThan(first.top),
      reason: 'unplaced blocks stack in order instead of overlapping',
    );

    await unmount(tester);
  });

  testWidgets('ink and text scroll together on the page', (tester) async {
    // The ink layer used to be Positioned.fill over a separately scrolling
    // ListView, so scrolling the text slid it out from under its own ink.
    // One shared surface inside one scroll view means they move as one.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'anchored'),
        ],
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notebook-canvas-surface')),
        matching: find.byType(NotebookInkCanvas),
      ),
      findsOneWidget,
      reason: 'the ink must live on the scrolling page surface',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notebook-canvas-surface')),
        matching: find.byKey(const ValueKey('notebook-block-b1')),
      ),
      findsOneWidget,
      reason: 'text blocks must live on that same surface',
    );

    await unmount(tester);
  });

  testWidgets('page content is actually on screen, not just in the tree',
      (tester) async {
    // find.byKey succeeds for a widget laid out far outside the viewport, so
    // the canvas tests above cannot tell "rendered where you can see it" from
    // "rendered 3000px off the side". On device that difference showed as a
    // completely blank page.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'visible please'),
        ],
      ),
    );

    final Rect screen = Offset.zero & tester.view.physicalSize /
        tester.view.devicePixelRatio;
    final Rect row =
        tester.getRect(find.byKey(const ValueKey('notebook-block-b1')));

    expect(
      row.overlaps(screen),
      isTrue,
      reason: 'the first block must be within the viewport on open, not '
          'parked off-canvas: got \$row against screen \$screen',
    );

    await unmount(tester);
  });

  testWidgets('the insert menu scrolls back to the top of the page',
      (tester) async {
    // With a long vertical roll it is still easy to end up far down it.
    // (2D panning is gone, so this is now just "go to the top".)
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'home', x: 20, y: 20),
        ],
      ),
    );

    final ScrollController controller = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('notebook-canvas-scroll')),
        )
        .controller!;
    controller.jumpTo(1500);
    await tester.pump();
    expect(controller.offset, 1500);

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back to start'));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      0,
      reason: 'Back to start returns to the top of the page',
    );

    await unmount(tester);
  });

  testWidgets('dragging a card persists its settled position', (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookDumpCardBlock(id: 'b1', dumpId: 'd1', x: 30, y: 200),
        ],
      ),
      dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
    );

    await tester.drag(find.text('Morning ideas'), const Offset(40, 25));
    await tester.pump();

    // The parent owns the truth: after the gesture settles it must be
    // rendering the card at the new spot, otherwise the card snaps back to
    // its old position the next time anything rebuilds the page.
    expect(
      tester.widget<NotebookDumpCard>(find.byType(NotebookDumpCard)).position,
      const Offset(70, 225),
    );

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookDumpCardBlock card = repository.saved.single.document.blocks
        .whereType<NotebookDumpCardBlock>()
        .single;
    expect(card.x, closeTo(70, 0.5));
    expect(card.y, closeTo(225, 0.5));
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('the ink layer does not hide the page beneath it',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'hello notebook'),
        ],
      ),
    );

    // The canvas is the TOP layer (it must take the pointer in draw mode) and
    // paints an opaque black background of its own. Rasterise the page and
    // prove real light pixels survive: a regression that drops the cutout
    // filter would leave a uniformly black page with invisible text.
    final ui.Image image = await tester.runAsync(() async {
      final RenderRepaintBoundary boundary =
          tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      return boundary.toImage();
    }) as ui.Image;
    addTearDown(image.dispose);

    final ByteData bytes = (await tester.runAsync<ByteData?>(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    var lightPixels = 0;
    for (int offset = 0; offset + 3 < bytes.lengthInBytes; offset += 4) {
      if (bytes.getUint8(offset) > 200 &&
          bytes.getUint8(offset + 1) > 200 &&
          bytes.getUint8(offset + 2) > 200) {
        lightPixels++;
      }
    }
    expect(
      lightPixels,
      greaterThan(0),
      reason: 'typed content must remain visible under the ink layer',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('a JUST-INSERTED card can be dragged', (tester) async {
    // Jeff: "when you ADD IN a dump or text note etc. into the notebooks, it
    // can no longer be dragged". The distinction from an already-saved card
    // matters: insertion is what might leave it in a non-draggable state.
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1'),
      dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
    );

    // Insert it through the real menu, exactly as a user would.
    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dump'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Morning ideas').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final Finder card = find.byType(NotebookDumpCard);
    expect(card, findsOneWidget, reason: 'the dump must be on the page');
    final Rect before = tester.getRect(card);

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Morning ideas')));
    for (int i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(2, 3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byType(NotebookDumpCard)).topLeft,
      isNot(before.topLeft),
      reason: 'a freshly inserted card must be draggable',
    );

    await unmount(tester);
  });

  testWidgets('a card drags when the finger moves in small steps',
      (tester) async {
    // Jeff: "when you add in a dump or text note etc. into the notebooks, it
    // can no longer be dragged and put somewhere else on the screen".
    //
    // tester.drag() emits ONE move event covering the whole distance, so the
    // card's recognizer crosses its threshold on the very first event and
    // wins the arena. A real finger emits a stream of 1-3px moves, which lets
    // the page scroll -- whose own slop is smaller -- claim the gesture
    // first. This reproduces the real input stream.
    await mountEditor(
      tester,
      notebook: seeded(),
      dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
    );

    final Rect before =
        tester.getRect(find.byKey(const ValueKey('notebook-card-b3')));

    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.text('Morning ideas')));
    // 1.5px steps: below the scroll view's own slop per event, which is how a
    // slow finger moves. On device this speed failed while a fast swipe
    // worked.
    // 1px steps: no single event is anywhere near the 18px slop, which is
    // exactly the slow finger that failed on device.
    for (int i = 0; i < 60; i++) {
      await gesture.moveBy(const Offset(1.0, 1.0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final Rect after =
        tester.getRect(find.byKey(const ValueKey('notebook-card-b3')));

    expect(
      after.topLeft,
      isNot(before.topLeft),
      reason: 'a real finger drag must move the card, not scroll the page',
    );

    await unmount(tester);
  });

  testWidgets('a second drag still settles where the finger left the card',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookDumpCardBlock(id: 'b1', dumpId: 'd1', x: 30, y: 200),
        ],
      ),
      dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
    );

    // The first drag marks the page dirty. The second must still land: a
    // card that only moves while the dirty flag is flipping would snap back
    // to its previous spot on the next rebuild.
    await tester.drag(find.text('Morning ideas'), const Offset(40, 25));
    await tester.pump();
    await tester.drag(find.text('Morning ideas'), const Offset(-15, 30));
    await tester.pump();

    expect(
      tester.widget<NotebookDumpCard>(find.byType(NotebookDumpCard)).position,
      const Offset(55, 255),
    );

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookDumpCardBlock card = repository.saved.single.document.blocks
        .whereType<NotebookDumpCardBlock>()
        .single;
    expect(card.x, closeTo(55, 0.5));
    expect(card.y, closeTo(255, 0.5));
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('backing out with unsaved edits asks before discarding',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    await tester.enterText(textBlocks().first, 'unsaved words');
    await tester.pump();

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.byType(NotebookEditorScreen), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NotebookEditorScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Discard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(NotebookEditorScreen), findsNothing);
    expect(repository.saved, isEmpty);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('a clean notebook backs out without a prompt', (tester) async {
    await mountEditor(tester, notebook: seeded());

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(NotebookEditorScreen), findsNothing);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });
  testWidgets('the eraser toggle actually reaches the ink canvas',
      (tester) async {
    // Guards the failure mode that recurred through this project: a control
    // that flips a field nothing reads, so the feature does nothing on device
    // while looking complete in the toolbar. Asserts the canvas property, not
    // the button's own state.
    await mountEditor(tester, notebook: seeded());

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();

    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

    expect(canvas().erasing, isFalse, reason: 'draw mode starts on the pen');
    expect(find.byIcon(Icons.auto_fix_normal), findsOneWidget);

    await tester.tap(find.byIcon(Icons.auto_fix_normal));
    await tester.pump();

    expect(
      canvas().erasing,
      isTrue,
      reason: 'the toggle must be wired through to the canvas',
    );
    // The icon flips to a pen so the active tool is never ambiguous.
    expect(find.byIcon(Icons.edit), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit));
    await tester.pump();
    expect(canvas().erasing, isFalse, reason: 'toggles back to the pen');

    await unmount(tester);
  });

  testWidgets('leaving draw mode does not strand the eraser on',
      (tester) async {
    // Otherwise reopening the pen later silently starts in erase mode and the
    // next stroke deletes work instead of drawing it.
    await mountEditor(tester, notebook: seeded());

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.auto_fix_normal));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();

    expect(
      tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas)).erasing,
      isFalse,
      reason: 'the pen is the safe default when drawing resumes',
    );

    await unmount(tester);
  });

  /// Drags like a real finger: many small steps, each its own move event.
  ///
  /// tester.drag() emits ONE move covering the whole distance, which clears the
  /// touch slop on the first event and hands the grip recognizer the arena
  /// immediately. A finger emits a stream of 1-3px moves that the scrolling
  /// page competes for, so only this shape exercises the competition.
  Future<void> slowDrag(
    WidgetTester tester,
    Finder target,
    Offset total, {
    int steps = 30,
  }) async {
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(target));
    final Offset step = total / steps.toDouble();
    for (int i = 0; i < steps; i++) {
      await gesture.moveBy(step);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('a slow finger drags a text block', (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'movable', x: 40, y: 120),
        ],
      ),
    );

    await slowDrag(
      tester,
      find.byKey(const ValueKey('notebook-block-grip-b1')),
      const Offset(60, 90),
    );

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookTextBlock moved = repository.saved.single.document.blocks
        .whereType<NotebookTextBlock>()
        .single;
    expect(
      moved.x,
      closeTo(100, 2),
      reason: 'a slow horizontal drag must still move the block',
    );
    expect(
      moved.y,
      closeTo(210, 2),
      reason: 'the page scroll must not steal a slow vertical drag',
    );

    await unmount(tester);
  });

  testWidgets('a slow finger drags a checkbox block', (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookCheckboxBlock(id: 'c1', text: 'task', x: 40, y: 120),
        ],
      ),
    );

    await slowDrag(
      tester,
      find.byKey(const ValueKey('notebook-block-grip-c1')),
      const Offset(60, 90),
    );

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookCheckboxBlock moved = repository.saved.single.document.blocks
        .whereType<NotebookCheckboxBlock>()
        .single;
    expect(moved.x, closeTo(100, 2));
    expect(moved.y, closeTo(210, 2));

    await unmount(tester);
  });

  testWidgets('the page does not scroll while a block is dragged',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'movable', x: 40, y: 120),
        ],
      ),
    );

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final double before = scrollable.position.pixels;

    await slowDrag(
      tester,
      find.byKey(const ValueKey('notebook-block-grip-b1')),
      const Offset(0, 140),
    );

    expect(
      scrollable.position.pixels,
      before,
      reason: 'a grip drag must move the block, never scroll the page',
    );

    await unmount(tester);
  });

  testWidgets('a wobbly tap on the grip does not move the block',
      (tester) async {
    // A real finger never lands perfectly still. Under the slop the block must
    // stay put, or every tap near the grip nudges the layout.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'movable', x: 40, y: 120),
        ],
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('notebook-block-grip-b1'))),
    );
    await gesture.moveBy(const Offset(1.5, 1.0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookTextBlock block = repository.saved.single.document.blocks
        .whereType<NotebookTextBlock>()
        .single;
    expect(block.x, closeTo(40, 0.5), reason: 'a tap must not move the block');
    expect(block.y, closeTo(120, 0.5));

    await unmount(tester);
  });

  testWidgets('the page is held still only once a drag really starts',
      (tester) async {
    // The mechanism, asserted directly: a competing page scroll is what stole
    // slow block drags on device, and the fix is to hand the scrollable
    // NeverScrollableScrollPhysics for the life of the gesture. Asserting the
    // block's final position cannot see this -- the widget-test arena resolves
    // differently from a real touch screen, so removing the hold entirely
    // still passes a position assertion. This checks the physics itself.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'movable', x: 40, y: 120),
        ],
      ),
    );

    ScrollPhysics physics() => tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('notebook-canvas-scroll')),
        )
        .physics!;

    expect(physics(), isA<ClampingScrollPhysics>(),
        reason: 'the page scrolls normally at rest',);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('notebook-block-grip-b1'))),
    );
    await gesture.moveBy(const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      physics(),
      isA<ClampingScrollPhysics>(),
      reason: 'a wobble under the slop is a tap; the page must stay scrollable '
          'or an uncontested recognizer replays the wobble onto the block',
    );

    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 6));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      physics(),
      isA<NeverScrollableScrollPhysics>(),
      reason: 'past the slop the page must hold still so the grip keeps the '
          'gesture instead of losing the arena to the scroll',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      physics(),
      isA<ClampingScrollPhysics>(),
      reason: 'the page must scroll again once the finger lifts',
    );

    await unmount(tester);
  });

  testWidgets('the grip wins a drag against the page scroll', (tester) async {
    // Measured on the tablet, not theorised: an instrumented build logged the
    // grip recognizer being REJECTED after only 8.6px of travel, because the
    // enclosing scroll view claims a vertical drag long before Flutter's
    // 18px kTouchSlop. A threshold of 18 could never be reached, so the
    // earlier "hold the page once slop is crossed" fix never fired on device
    // and dragging a block by its grip did nothing at all.
    //
    // This drives the real screen with a slow finger and stops at 12px --
    // past the scroll's claim distance, still short of kTouchSlop -- so the
    // test fails for exactly the reason the device did.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'movable', x: 40, y: 120),
        ],
      ),
    );

    final Finder grip = find.byKey(const ValueKey('notebook-block-grip-b1'));
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(grip),
    );
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 1));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final NotebookTextBlock moved = repository.saved.single.document.blocks
        .whereType<NotebookTextBlock>()
        .single;
    expect(
      moved.y,
      closeTo(132, 2),
      reason: 'a 12px drag must move the block: the grip has to claim the '
          'gesture before the page scroll does',
    );

    await unmount(tester);
  });
}

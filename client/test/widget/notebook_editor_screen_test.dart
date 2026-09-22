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
import 'package:tangent/models/notebook_ruling.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/dump_picker_sheet.dart';
import 'package:tangent/widgets/notebook_dump_card.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

/// T4: the notebook editor — text/checkbox blocks over a draggable dump-card
/// layer under an ink canvas, a page-local pen toolbar, and an explicit save.

DumpRow _dumpRow(
  String id,
  String title, {
  String mode = 'brain_dump',
  String? transcript,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 17, 8),
      updatedAt: DateTime.utc(2026, 9, 17, 8),
      mode: mode,
      durationSeconds: mode == 'text_note' ? 0 : 95,
      title: title,
      transcript: transcript,
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
    bool setViewSize = true,
  }) async {
    if (setViewSize) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
    }
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
      'one unified toolbar: every tool is visible AND live before draw mode; '
      'tapping a tool activates draw mode with that tool', (tester) async {
    await mountEditor(tester, notebook: seeded());

    // The whole kit is on screen from the start — no second row drops down.
    expect(find.byType(PenSizeControl), findsOneWidget);
    expect(find.byIcon(Icons.undo), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notebook-redo')), findsOneWidget);
    expect(find.byKey(const ValueKey('notebook-lasso')), findsOneWidget);
    expect(find.byKey(const ValueKey('notebook-pen-style')), findsOneWidget);

    // Contract change (Jeff): every tool is tappable at ANY time — tapping
    // one activates draw mode with that tool, instead of being dead until
    // the Draw toggle is pressed first.
    IconButton toolButton(Key key) =>
        tester.widget<IconButton>(find.byKey(key));
    expect(
      toolButton(const ValueKey<String>('notebook-lasso')).onPressed,
      isNotNull,
      reason: 'lasso must be tappable outside draw mode',
    );
    expect(
      toolButton(const ValueKey<String>('notebook-pen-style')).onPressed,
      isNotNull,
      reason: 'the nib must be tappable outside draw mode',
    );
    expect(
      tester
          .widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas))
          .drawingEnabled,
      isFalse,
    );

    // Tapping the lasso from cold enters draw mode, lassoing.
    await tester.tap(find.byKey(const ValueKey('notebook-lasso')));
    await tester.pump();
    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));
    expect(
      canvas().drawingEnabled,
      isTrue,
      reason: 'a tool tap activates draw mode itself',
    );
    expect(canvas().lassoing, isTrue);

    // Draw toggle still exits, and the toolbar stays put (disabled tools
    // never disappear — same row, same places).
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    expect(canvas().drawingEnabled, isFalse);
    expect(find.byType(PenSizeControl), findsOneWidget);
    expect(find.byIcon(Icons.undo), findsOneWidget);

    // Tapping the eraser from cold enters draw mode, erasing.
    await tester.tap(find.byIcon(Icons.auto_fix_normal));
    await tester.pump();
    expect(canvas().drawingEnabled, isTrue);
    expect(canvas().erasing, isTrue);
    expect(
      canvas().lassoing,
      isFalse,
      reason: 'eraser and lasso stay exclusive',
    );

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();

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
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-as-card')));
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
    await tester.tap(find.byKey(const ValueKey('import-as-card')));
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

    final Finder remove =
        find.byKey(const ValueKey('notebook-block-remove-b1'));
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

  /// Reads the block keys in the order they are laid out on the page.
  ///
  /// Asserting on rendered order rather than on the screen's private State
  /// keeps this honest about what the user actually sees, and survives a
  /// refactor of the backing list.
  List<String> renderedBlockOrder(WidgetTester tester) {
    // Anchor the prefix: 'notebook-block-grip-' and '-remove-' share it, so an
    // unanchored startsWith counts three widgets per block.
    final RegExp blockKey = RegExp(r'^notebook-block-[^-]');
    return tester
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
  }

  testWidgets('a new text block lands below the item being edited',
      (tester) async {
    // Appending to the very end scatters a page being written top-to-bottom:
    // the user is working in the middle of the document and the new block
    // appears far below, off screen. Enter already inserts in place
    // (_splitCheckboxBlock); the toolbar buttons must agree with it.
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

    // Put the caret in the FIRST block, so "the end" and "below the caret"
    // are different answers and the test can tell them apart.
    await tester.tap(find.byKey(const ValueKey('notebook-checkbox-block-b1')));
    await tester.pumpAndSettle();

    // PROBE: what actually holds focus after the tap?
    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text block'));
    await tester.pumpAndSettle();

    final List<String> order = renderedBlockOrder(tester);
    expect(order.length, 3, reason: 'exactly one block was added');
    expect(
      order.first,
      'notebook-block-b1',
      reason: 'the focused block stays put',
    );
    expect(
      order.last,
      'notebook-block-b2',
      reason: 'the new block sits BETWEEN the focused block and what followed '
          'it, not appended after everything',
    );
  });

  testWidgets('a new checkbox lands below the item being edited',
      (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checkbox'));
    await tester.pumpAndSettle();

    final List<String> order = renderedBlockOrder(tester);
    expect(order.length, 3);
    expect(order.first, 'notebook-block-b1');
    expect(
      order.last,
      'notebook-block-b2',
      reason: 'the new checkbox goes below the caret, matching what Enter does',
    );
  });

  testWidgets('with nothing focused a new block still appends to the end',
      (tester) async {
    // No caret means no "here" to insert at, and the end of the page is the
    // only answer that does not move the user somewhere they did not ask for.
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

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text block'));
    await tester.pumpAndSettle();

    final List<String> order = renderedBlockOrder(tester);
    expect(order.length, 3);
    expect(
      order.sublist(0, 2),
      <String>['notebook-block-b1', 'notebook-block-b2'],
      reason: 'the existing blocks keep their order and the new one is last',
    );
  });

  /// The ruling layer's painter, or null when it is not in the tree.
  NotebookRulingPainter? rulingPainter(WidgetTester tester) {
    final Finder finder = find.byKey(const ValueKey('notebook-ruling'));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<CustomPaint>(finder).painter as NotebookRulingPainter?;
  }

  testWidgets('a ruled notebook paints its lines', (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1', ruling: NotebookRuling.medium),
    );

    expect(
      rulingPainter(tester)?.ruling,
      NotebookRuling.medium,
      reason: 'the stored ruling must reach the painter',
    );
  });

  testWidgets('a blank notebook draws no lines', (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1', ruling: NotebookRuling.blank),
    );

    expect(rulingPainter(tester)?.ruling, NotebookRuling.blank);
  });

  testWidgets('the ruling covers the whole page, not just the viewport',
      (tester) async {
    // The page is a vertical roll taller than the screen. Painting only the
    // visible part would leave the lines behind as soon as the user scrolls,
    // and the page would run out of ruling at the bottom.
    await mountEditor(
      tester,
      notebook: testNotebook(
        id: 'nb-1',
        ruling: NotebookRuling.medium,
        // Content low on the page, so the roll is genuinely taller than the
        // viewport. An empty notebook is exactly one screen, which would make
        // "covers the whole page" pass without proving anything.
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'b1', text: 'far down', x: 20, y: 1800),
        ],
      ),
    );
    final Size rulingSize =
        tester.getSize(find.byKey(const ValueKey('notebook-ruling')));
    final Size surfaceSize =
        tester.getSize(find.byKey(const ValueKey('notebook-canvas-surface')));

    expect(
      rulingSize.height,
      surfaceSize.height,
      reason: 'the ruling must be as tall as the scrollable page',
    );
    // The visible canvas is the viewport minus the app bar. The page must be
    // taller than that, or "covers the whole page" proves nothing.
    final double visibleCanvasHeight = tester
        .getSize(
          find.byKey(const ValueKey('notebook-canvas-scroll')),
        )
        .height;
    expect(
      surfaceSize.height,
      greaterThan(visibleCanvasHeight),
      reason: 'the page must be a roll taller than what is on screen',
    );
  });

  testWidgets('the ruling does not swallow taps meant for the page',
      (tester) async {
    // A full-page layer above the background is exactly the shape of thing
    // that silently breaks drawing and card dragging.
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1', ruling: NotebookRuling.medium),
    );

    // IgnorePointer is common in Flutter's own tree, so assert on the one
    // wrapping the ruling specifically and that it is actually enabled.
    final IgnorePointer guard = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('notebook-ruling')),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(
      guard.ignoring,
      isTrue,
      reason: 'the ruling must be invisible to hit testing, or it would eat '
          'pen strokes and card drags',
    );
  });

  testWidgets('cycling the ruling changes what is painted and saves it',
      (tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(id: 'nb-1', ruling: NotebookRuling.blank),
    );

    expect(rulingPainter(tester)?.ruling, NotebookRuling.blank);

    await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-ruling-item')));
    await tester.pumpAndSettle();

    expect(
      rulingPainter(tester)?.ruling,
      NotebookRuling.small,
      reason: 'blank cycles to small',
    );

    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      publishedNotebooks.last.ruling,
      NotebookRuling.small,
      reason: 'a ruling the user chose must survive leaving the screen',
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

  testWidgets(
      'the checkbox field asks Android for an action key, not a newline',
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

    final Rect screen =
        Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
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
    await tester.tap(find.byKey(const ValueKey('import-as-card')));
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

  testWidgets('backing out with unsaved edits saves them on the way out',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    await tester.enterText(textBlocks().first, 'unsaved words');
    await tester.pump();

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // No dialog, no data loss: the notebook persists and the screen closes.
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(NotebookEditorScreen), findsNothing);
    expect(repository.saved, hasLength(1));
    expect(
      repository.saved.single.document.blocks
          .whereType<NotebookTextBlock>()
          .map((NotebookTextBlock b) => b.text),
      contains('unsaved words'),
      reason: 'the edit made right before backing out must be in the save',
    );
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

  testWidgets('long-pressing the pen opens its palette and picks a colour',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    await tester.longPress(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();

    // The pen palette, not the highlighter's.
    expect(
      find.byKey(const ValueKey('notebook-ink-swatch-red')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('notebook-ink-swatch-pink')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-red')));
    await tester.pumpAndSettle();

    final NotebookInkCanvas canvas =
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));
    expect(canvas.colour, InkColor.red);
    // Picking a colour IS choosing to draw: from cold, the pick must land
    // in draw mode or the very next stroke silently does nothing.
    expect(canvas.drawingEnabled, isTrue);
    expect(canvas.tool, InkTool.pen);

    await unmount(tester);
  });

  testWidgets('a dismissed palette leaves the colour alone', (tester) async {
    await mountEditor(tester, notebook: seeded());
    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

    // Put a NON-default colour on the pen first, so a sneaky reset to the
    // default is visible.
    await tester.longPress(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-red')));
    await tester.pumpAndSettle();
    expect(canvas().colour, InkColor.red);

    // Open the palette again and dismiss it without choosing: tap outside
    // the menu. The colour must survive untouched.
    await tester.longPress(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(
      canvas().colour,
      InkColor.red,
      reason: 'dismissing the palette must never reset the colour',
    );

    await unmount(tester);
  });

  testWidgets('the highlighter activates draw mode and clears other tools',
      (tester) async {
    await mountEditor(tester, notebook: seeded());

    // From cold, per the toolbar contract: a tool tap enters draw mode.
    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();

    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));
    expect(canvas().drawingEnabled, isTrue);
    expect(canvas().tool, InkTool.highlighter);
    expect(canvas().erasing, isFalse);
    expect(canvas().lassoing, isFalse);

    await unmount(tester);
  });

  testWidgets('each tool remembers its own colour', (tester) async {
    await mountEditor(tester, notebook: seeded());
    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

    await tester.longPress(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-blue')));
    await tester.pumpAndSettle();
    expect(canvas().colour, InkColor.blue);

    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();
    expect(canvas().colour, InkColor.yellow, reason: 'highlighter default');

    await tester.longPress(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notebook-ink-swatch-pink')));
    await tester.pumpAndSettle();
    expect(canvas().colour, InkColor.pink);

    // Back to the pen: it still has the blue chosen earlier.
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    expect(canvas().tool, InkTool.pen);
    expect(canvas().colour, InkColor.blue);

    await unmount(tester);
  });

  testWidgets('leaving draw mode resets to the pen', (tester) async {
    await mountEditor(tester, notebook: seeded());
    NotebookInkCanvas canvas() =>
        tester.widget<NotebookInkCanvas>(find.byType(NotebookInkCanvas));

    await tester.tap(find.byKey(const ValueKey('notebook-highlighter')));
    await tester.pump();
    expect(canvas().tool, InkTool.highlighter);

    // A stranded highlighter would make the next stroke a wash of colour
    // when the user expected handwriting — same rule as the eraser.
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    expect(canvas().tool, InkTool.pen);

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

    expect(
      physics(),
      isA<ClampingScrollPhysics>(),
      reason: 'the page scrolls normally at rest',
    );

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

  group('cross-device scale-to-fit', () {
    // Positions persist in CANONICAL page space (720 logical px wide). A
    // narrower viewport renders the same layout scaled by viewport/720 —
    // content authored on a tablet must not sit off a phone's right edge:
    // block x=600 on a 360-wide phone renders at 300, fully on screen.
    testWidgets('blocks render scaled down on a narrow viewport',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          title: 'Scaled',
          blocks: <NotebookBlock>[
            const NotebookTextBlock(
              id: 'b1',
              text: 'far right',
              x: 600,
              y: 100,
            ),
          ],
        ),
        setViewSize: false,
      );

      final Offset surface = tester.getTopLeft(
        find.byKey(const ValueKey('notebook-canvas-surface')),
      );
      final Offset topLeft = tester.getTopLeft(
            find.byKey(const ValueKey('notebook-block-b1')),
          ) -
          surface;
      // 600 * (360/720) = 300; the whole block must start on-screen.
      expect(topLeft.dx, moreOrLessEquals(300, epsilon: 1));
      expect(topLeft.dy, moreOrLessEquals(50, epsilon: 1));
      await unmount(tester);
    });

    testWidgets('ink beyond the typed column is not clipped on a narrow screen',
        (tester) async {
      // Jeff's Fold, exactly: the 475dp COVER screen clipped the right-hand
      // end of every line ("entry int…", "of softw…") while the 932dp inner
      // screen was fine. Cause: the scale denominator was the TYPED COLUMN
      // width (720), but handwriting uses the full page area — this Journal
      // page's ink reaches x=808, so everything past 720 fell off the edge.
      //
      // The page must scale against its real content, so the rightmost ink
      // lands inside the viewport.
      const double inkRight = 808;
      tester.view.physicalSize = const Size(475, 751);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          title: 'Journal',
          strokes: <InkStroke>[
            const InkStroke(
              id: 's1',
              width: 3,
              points: <InkPoint>[
                InkPoint(x: 48, y: 100),
                InkPoint(x: inkRight, y: 100),
              ],
            ),
          ],
        ),
        setViewSize: false,
      );

      // Measure what the widget ACTUALLY laid out, never a scale recomputed
      // here: the canvas sits inside the FittedBox, so its own size IS the
      // canonical page width the editor chose. Asserting on a locally
      // derived scale proves nothing (an earlier version of this test stayed
      // green against the unfixed code).
      final double canonicalWidth =
          tester.getSize(find.byType(NotebookInkCanvas)).width;
      expect(
        canonicalWidth,
        greaterThanOrEqualTo(inkRight),
        reason: 'the canonical page must be wide enough to hold ink at '
            'x=$inkRight; a 720-wide page clips it off the right edge',
      );

      final Rect surface = tester.getRect(
        find.byKey(const ValueKey('notebook-canvas-surface')),
      );
      expect(
        surface.width,
        moreOrLessEquals(475, epsilon: 1),
        reason: 'the surface still fills the viewport width',
      );
      await unmount(tester);
    });

    testWidgets('a page inside the typed column keeps the column scale',
        (tester) async {
      // The guard: widening the denominator must not shrink ordinary pages.
      // Ink well inside the column leaves the 720 basis untouched, so a
      // block at x=600 still renders at 300 on a 360-wide screen.
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          title: 'Narrow ink',
          blocks: <NotebookBlock>[
            const NotebookTextBlock(id: 'b1', text: 'far right', x: 600, y: 100),
          ],
          strokes: <InkStroke>[
            const InkStroke(
              id: 's1',
              width: 3,
              points: <InkPoint>[
                InkPoint(x: 10, y: 10),
                InkPoint(x: 200, y: 10),
              ],
            ),
          ],
        ),
        setViewSize: false,
      );

      final Offset surface = tester.getTopLeft(
        find.byKey(const ValueKey('notebook-canvas-surface')),
      );
      final Offset topLeft = tester.getTopLeft(
            find.byKey(const ValueKey('notebook-block-b1')),
          ) -
          surface;
      expect(topLeft.dx, moreOrLessEquals(300, epsilon: 1));
      await unmount(tester);
    });

    testWidgets('a wide image block is not clipped on a narrow screen',
        (tester) async {
      // Ink is not the only thing that escapes the typed column. An image
      // carries its OWN width and sits at its own x (text/checkbox rows are
      // width-clamped to the page, so they self-limit and need no term).
      // An image at x=600 w=400 reaches 1000 and was clipped exactly like
      // the ink was.
      tester.view.physicalSize = const Size(475, 751);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          title: 'Wide image',
          blocks: <NotebookBlock>[
            const NotebookImageBlock(
              id: 'img1',
              data: '',
              mime: 'image/png',
              x: 600,
              y: 50,
              width: 400,
              height: 200,
            ),
          ],
        ),
        setViewSize: false,
      );

      final double canonicalWidth =
          tester.getSize(find.byType(NotebookInkCanvas)).width;
      expect(
        canonicalWidth,
        greaterThanOrEqualTo(1000),
        reason: 'the page must be wide enough to hold an image whose right '
            'edge is at x=1000; a 720-wide page cuts it off',
      );
      await unmount(tester);
    });

    testWidgets('dragging a block on a narrow viewport stores canonical x/y',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          title: 'Scaled drag',
          blocks: <NotebookBlock>[
            const NotebookTextBlock(id: 'b1', text: 'movable', x: 100, y: 100),
          ],
        ),
        setViewSize: false,
      );

      // Drag the block 60 screen px right, 40 down: at scale 0.5 that is
      // 120/80 in canonical space.
      final Finder handle =
          find.byKey(const ValueKey('notebook-block-grip-b1'));
      final TestGesture drag = await tester.startGesture(
        tester.getCenter(handle),
      );
      await drag.moveBy(const Offset(60, 40));
      await tester.pump(const Duration(milliseconds: 16));
      await drag.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.save));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final NotebookTextBlock moved = repository.saved.single.document.blocks
          .whereType<NotebookTextBlock>()
          .single;
      expect(moved.x, moreOrLessEquals(220, epsilon: 2)); // 100 + 120
      expect(moved.y, moreOrLessEquals(180, epsilon: 2)); // 100 + 80
      await unmount(tester);
    });

    testWidgets('ink drawn on a narrow viewport stores canonical points',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: testNotebook(id: 'nb-1', title: 'Scaled ink'),
        setViewSize: false,
      );

      await tester.tap(find.byIcon(Icons.draw));
      await tester.pumpAndSettle();
      final Offset surface = tester.getTopLeft(
        find.byKey(const ValueKey('notebook-canvas-surface')),
      );
      // A stroke at screen x 90..180 is canonical 180..360 at scale 0.5.
      final TestGesture pen = await tester.startGesture(
        surface + const Offset(90, 100),
        kind: ui.PointerDeviceKind.stylus,
      );
      await pen.moveTo(surface + const Offset(180, 100));
      await pen.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.save));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final InkStroke stroke = repository.saved.single.ink.strokes.single;
      expect(
        stroke.points.first.x,
        moreOrLessEquals(180, epsilon: 3),
        reason: 'screen x=90 at scale 0.5 must persist as canonical 180',
      );
      expect(
        stroke.points.last.x,
        moreOrLessEquals(360, epsilon: 3),
        reason: 'screen x=180 at scale 0.5 must persist as canonical 360',
      );
      await unmount(tester);
    });
  });

  group('smart lasso over blocks', () {
    // The dump card 'b3' anchors at canonical (24, 120). The viewport is
    // 1080 wide (>= 720), so canonical space renders 1:1 and screen taps
    // inside the editor Stack map straight onto canonical coordinates.
    Future<void> enterLasso(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.draw));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('notebook-lasso')));
      await tester.pump();
    }

    Offset canvasOrigin(WidgetTester tester) => tester.getTopLeft(
          find.byKey(NotebookInkCanvas.backgroundKey),
        );

    /// Draws a loop around the dump card's anchor region.
    Future<void> lassoAroundCard(WidgetTester tester) async {
      final Offset origin = canvasOrigin(tester);
      final TestGesture g = await tester.createGesture();
      await g.down(origin + const Offset(5, 90));
      await tester.pump();
      for (final Offset p in const <Offset>[
        Offset(400, 90),
        Offset(400, 260),
        Offset(5, 260),
        Offset(5, 95),
      ]) {
        await g.moveTo(origin + p);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('a loop over ~half the card selects; a corner clip does not',
        (WidgetTester tester) async {
      await mountEditor(
        tester,
        notebook: seeded(),
        dumps: <DumpRow>[_dumpRow('d1', 'Standup notes')],
      );
      await enterLasso(tester);
      final Finder deleteButton =
          find.byKey(const ValueKey<String>('notebook-lasso-delete'));
      final Offset origin = canvasOrigin(tester);

      // Card b3 spans canonical x 24-324. A loop out to x=130 covers only
      // ~33% of its area -- under the 40% threshold, so no selection.
      Future<void> loopTo(double rightEdge) async {
        final TestGesture g = await tester.createGesture();
        await g.down(origin + const Offset(5, 90));
        await tester.pump();
        for (final Offset p in <Offset>[
          Offset(rightEdge, 90),
          Offset(rightEdge, 260),
          const Offset(5, 260),
          const Offset(5, 95),
        ]) {
          await g.moveTo(origin + p);
          await tester.pump();
        }
        await g.up();
        await tester.pump();
      }

      await loopTo(130);
      expect(
        tester.widget<IconButton>(deleteButton).onPressed,
        isNull,
        reason: 'a third of the card is a clipped corner, not a grab',
      );

      // Out to x=180 the loop holds ~50% of the card: past the 40%
      // threshold, so the card is caught.
      await loopTo(180);
      expect(
        tester.widget<IconButton>(deleteButton).onPressed,
        isNotNull,
        reason: 'half the card inside the loop must select it',
      );
      await unmount(tester);
    });

    testWidgets('circling a recording card arms delete and removes it',
        (WidgetTester tester) async {
      await mountEditor(
        tester,
        notebook: seeded(),
        dumps: <DumpRow>[_dumpRow('d1', 'Standup notes')],
      );
      await enterLasso(tester);

      final Finder deleteButton =
          find.byKey(const ValueKey<String>('notebook-lasso-delete'));
      expect(
        tester.widget<IconButton>(deleteButton).onPressed,
        isNull,
        reason: 'nothing selected yet',
      );

      await lassoAroundCard(tester);
      expect(
        tester.widget<IconButton>(deleteButton).onPressed,
        isNotNull,
        reason: 'a blocks-only catch must arm delete',
      );

      await tester.tap(deleteButton);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('notebook-card-b3')),
        findsNothing,
        reason: 'the circled card is deleted',
      );
      // Ink-less delete must not touch the other blocks.
      expect(textBlocks(), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('dragging the selection moves the circled card',
        (WidgetTester tester) async {
      await mountEditor(
        tester,
        notebook: seeded(),
        dumps: <DumpRow>[_dumpRow('d1', 'Standup notes')],
      );
      await enterLasso(tester);
      await lassoAroundCard(tester);

      final Finder card =
          find.byKey(const ValueKey<String>('notebook-card-b3'));
      final Offset before = tester.getTopLeft(card);

      final Offset origin = canvasOrigin(tester);
      final TestGesture g = await tester.createGesture();
      // Down inside the card's footprint (anchor 24,120 + padding).
      await g.down(origin + const Offset(100, 150));
      await tester.pump();
      await g.moveTo(origin + const Offset(180, 250));
      await tester.pump();
      await g.up();
      await tester.pump();

      final Offset after = tester.getTopLeft(card);
      expect(after.dx - before.dx, moreOrLessEquals(80, epsilon: 1));
      expect(after.dy - before.dy, moreOrLessEquals(100, epsilon: 1));
      await unmount(tester);
    });
  });

  group('lasso block footprint is measured, not guessed', () {
    // A placed text row lays out as wide as the page column allows (720
    // canonical px here) — far wider than the old nominal 300x90 guess.
    // The lasso must catch the row the user actually sees.
    Notebook wideRowNotebook() => testNotebook(
          id: 'nb-1',
          blocks: const <NotebookBlock>[
            NotebookTextBlock(
              id: 'wt',
              text: 'a wide row of words that spans the whole page column',
              x: 24,
              y: 400,
            ),
          ],
        );

    Future<void> enterLasso(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.draw));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('notebook-lasso')));
      await tester.pump();
    }

    Finder wideRow() =>
        find.byKey(const ValueKey<String>('notebook-block-wt'));

    Finder deleteButton() =>
        find.byKey(const ValueKey<String>('notebook-lasso-delete'));

    /// Drags a rectangular lasso loop, corner to corner, in screen
    /// coordinates.
    Future<void> loopRect(WidgetTester tester, Rect r) async {
      final TestGesture g = await tester.createGesture();
      await g.down(r.topLeft);
      await tester.pump();
      for (final Offset p in <Offset>[
        r.topRight,
        r.bottomRight,
        r.bottomLeft,
        r.topLeft + const Offset(0, 5),
      ]) {
        await g.moveTo(p);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
    }

    testWidgets("a loop around a wide row's real right half catches it",
        (WidgetTester tester) async {
      await mountEditor(tester, notebook: wideRowNotebook());
      await enterLasso(tester);

      final Rect row = tester.getRect(wideRow());
      // The discriminating geometry needs the row to dwarf the nominal
      // guess: the loop below starts at the row's midpoint, which must lie
      // beyond the nominal footprint's right edge (anchor.x + 300).
      expect(
        row.width,
        greaterThan(600),
        reason: 'harness must lay the row out wider than twice the nominal '
            '300 so the loop below can discriminate real from guessed',
      );

      // >40% of the REAL footprint (3 of 6 sample columns, every sample
      // row) is inside this loop, but ZERO samples of a nominal 300x90
      // footprint are — under the guess this loop selects nothing.
      await loopRect(
        tester,
        Rect.fromLTRB(
          row.left + row.width / 2,
          row.top - 30,
          row.right + 30,
          row.bottom + 30,
        ),
      );

      expect(
        tester.widget<IconButton>(deleteButton()).onPressed,
        isNotNull,
        reason: 'half the row the user sees is inside the loop; the lasso '
            'must test the measured footprint, not the 300x90 guess',
      );
      await unmount(tester);
    });

    testWidgets('clipping only a corner of the wide row does not catch it',
        (WidgetTester tester) async {
      await mountEditor(tester, notebook: wideRowNotebook());
      await enterLasso(tester);
      final Rect row = tester.getRect(wideRow());

      // Only the rightmost sample column (at most 4 of 24 samples, ~17%)
      // can fall inside: under the 40% threshold, a clip is not a grab.
      await loopRect(
        tester,
        Rect.fromLTRB(
          row.left + row.width * 0.88,
          row.top - 20,
          row.right + 20,
          row.bottom + 20,
        ),
      );

      expect(
        tester.widget<IconButton>(deleteButton()).onPressed,
        isNull,
        reason: 'a loop clipping one corner of the row is not a grab: the '
            '40% threshold holds for measured footprints too',
      );
      await unmount(tester);
    });

    testWidgets('a caught wide row drags from anywhere on its real footprint',
        (WidgetTester tester) async {
      await mountEditor(tester, notebook: wideRowNotebook());
      await enterLasso(tester);
      final Rect row = tester.getRect(wideRow());

      // Encircle the whole row, then grab it well past the nominal 300x90
      // region: 70% along the real width. The loop hugs the left edge from
      // on-screen (x=6) — a down-point at negative x never reaches the page.
      await loopRect(
        tester,
        Rect.fromLTRB(6, row.top - 30, row.right + 30, row.bottom + 30),
      );
      expect(
        tester.widget<IconButton>(deleteButton()).onPressed,
        isNotNull,
        reason: 'encircling the whole row must select it',
      );

      final Offset grab = Offset(row.left + row.width * 0.7, row.center.dy);
      final TestGesture g = await tester.createGesture();
      await g.down(grab);
      await tester.pump();
      await g.moveTo(grab + const Offset(60, 40));
      await tester.pump();
      await g.up();
      await tester.pump();

      final Rect after = tester.getRect(wideRow());
      expect(
        after.left - row.left,
        moreOrLessEquals(60, epsilon: 1),
        reason: 'the drag began on the row the user sees; the hit test '
            'must use the measured footprint',
      );
      expect(after.top - row.top, moreOrLessEquals(40, epsilon: 1));
      await unmount(tester);
    });

    testWidgets('measurement stays canonical when the page renders scaled',
        (WidgetTester tester) async {
      // A 540-wide viewport renders the 720-wide canonical page at 0.75
      // scale. Block RenderBoxes lay out in canonical space (the FittedBox
      // scales paint and hit-testing only), so the measured size must be
      // used as-is: converting it through the screen transform would
      // shrink the footprint by the scale and drop this catch below 40%.
      tester.view.physicalSize = const Size(540, 1200);
      tester.view.devicePixelRatio = 1.0;
      await mountEditor(
        tester,
        notebook: wideRowNotebook(),
        setViewSize: false,
      );
      await enterLasso(tester);

      final Rect row = tester.getRect(wideRow());
      await loopRect(
        tester,
        Rect.fromLTRB(
          row.left + row.width / 2,
          row.top - 20,
          row.right + 6,
          row.bottom + 20,
        ),
      );

      expect(
        tester.widget<IconButton>(deleteButton()).onPressed,
        isNotNull,
        reason: 'the same right-half loop must catch at any page scale: '
            'RenderBox sizes are already canonical',
      );
      await unmount(tester);
    });
  });

  group('import shape and content-aware insert', () {
    Future<void> importDump(WidgetTester tester, String pickKey) async {
      await tester.tap(find.byKey(const ValueKey('notebook-insert-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dump'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(pickKey)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dump-picker-add')));
      await tester.pumpAndSettle();
    }

    testWidgets('confirming the picker asks Audio bubble or Text',
        (tester) async {
      await mountEditor(
        tester,
        notebook: testNotebook(id: 'nb-1'),
        dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
      );

      await importDump(tester, 'dump-pick-d1');

      expect(find.byKey(const ValueKey('import-as-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('import-as-text')), findsOneWidget);
      expect(
        find.byType(NotebookDumpCard),
        findsNothing,
        reason: 'nothing is inserted before the user chooses a shape',
      );

      await unmount(tester);
    });

    testWidgets('choosing Text inserts the transcript as a text box',
        (tester) async {
      await mountEditor(
        tester,
        notebook: testNotebook(id: 'nb-1'),
        dumps: <DumpRow>[
          _dumpRow(
            'd1',
            'Morning ideas',
            transcript: 'remember to buy solder and flux',
          ),
        ],
      );

      await importDump(tester, 'dump-pick-d1');
      await tester.tap(find.byKey(const ValueKey('import-as-text')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(NotebookDumpCard), findsNothing);
      expect(
        find.text('remember to buy solder and flux'),
        findsOneWidget,
        reason: 'the transcript must land in an editable text box',
      );

      await tester.tap(find.byIcon(Icons.save));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final List<NotebookTextBlock> texts = repository
          .saved.single.document.blocks
          .whereType<NotebookTextBlock>()
          .toList();
      expect(texts, hasLength(1));
      expect(texts.single.text, 'remember to buy solder and flux');
      expect(tester.takeException(), isNull);

      await unmount(tester);
    });

    testWidgets('a dump with no transcript still imports as text, honestly',
        (tester) async {
      await mountEditor(
        tester,
        notebook: testNotebook(id: 'nb-1'),
        dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
      );

      await importDump(tester, 'dump-pick-d1');
      await tester.tap(find.byKey(const ValueKey('import-as-text')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('no transcript'),
        findsOneWidget,
        reason: 'an empty text box would read as a broken import',
      );

      await unmount(tester);
    });

    testWidgets('imported cards land below existing content, not on top',
        (tester) async {
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          blocks: const <NotebookBlock>[
            NotebookTextBlock(id: 'b1', text: 'placed low', x: 16, y: 600),
          ],
          strokes: <InkStroke>[
            InkStroke(
              id: 's-1',
              width: 3,
              points: const <InkPoint>[
                InkPoint(x: 100, y: 700),
                InkPoint(x: 200, y: 740),
              ],
            ),
          ],
        ),
        dumps: <DumpRow>[_dumpRow('d1', 'Morning ideas')],
      );

      await importDump(tester, 'dump-pick-d1');
      await tester.tap(find.byKey(const ValueKey('import-as-card')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.save));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final NotebookDumpCardBlock card = repository.saved.single.document.blocks
          .whereType<NotebookDumpCardBlock>()
          .single;
      expect(
        card.y,
        greaterThan(740),
        reason: 'the new card must land below the lowest existing content '
            '(text at 600, ink to 740), never on top of it',
      );
      expect(tester.takeException(), isNull);

      await unmount(tester);
    });

    testWidgets('text imports land below existing content too', (tester) async {
      await mountEditor(
        tester,
        notebook: testNotebook(
          id: 'nb-1',
          blocks: const <NotebookBlock>[
            NotebookTextBlock(id: 'b1', text: 'placed low', x: 16, y: 500),
          ],
        ),
        dumps: <DumpRow>[
          _dumpRow('d1', 'Morning ideas', transcript: 'the transcript'),
        ],
      );

      await importDump(tester, 'dump-pick-d1');
      await tester.tap(find.byKey(const ValueKey('import-as-text')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.save));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final List<NotebookTextBlock> texts = repository
          .saved.single.document.blocks
          .whereType<NotebookTextBlock>()
          .toList();
      final NotebookTextBlock imported = texts
          .singleWhere((NotebookTextBlock t) => t.text == 'the transcript');
      expect(
        imported.y,
        isNotNull,
        reason: 'imported text is placed, not flow-laid over placed blocks',
      );
      expect(imported.y, greaterThan(500));

      await unmount(tester);
    });
  });
}

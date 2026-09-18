// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

  testWidgets('the page is an infinite canvas that pans and zooms',
      (tester) async {
    // Jeff: "There needs to be an infinite canvas option". The page used to be
    // exactly one screen: ink was Positioned.fill, so there was nowhere to
    // draw past the first screenful.
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    final Finder viewer = find.byKey(const ValueKey('notebook-canvas-viewer'));
    expect(viewer, findsOneWidget, reason: 'the page must be pan/zoomable');

    final InteractiveViewer iv = tester.widget<InteractiveViewer>(viewer);
    expect(
      iv.constrained,
      isFalse,
      reason: 'an unconstrained child is what makes the canvas bigger than '
          'the viewport',
    );
    expect(iv.scaleEnabled, isTrue, reason: 'pinch-to-zoom is required');

    await unmount(tester);
  });

  testWidgets('one finger draws in draw mode instead of panning the canvas',
      (tester) async {
    // InteractiveViewer pans with ONE finger, which would fight the pen. In
    // draw mode one-finger pan is therefore off: the finger inks, and two
    // fingers still pinch/zoom.
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    InteractiveViewer viewer() => tester.widget<InteractiveViewer>(
          find.byKey(const ValueKey('notebook-canvas-viewer')),
        );

    expect(
      viewer().panEnabled,
      isTrue,
      reason: 'with the pen down you must be able to drag the page around',
    );

    await tester.tap(find.byIcon(Icons.draw));
    await tester.pumpAndSettle();

    expect(
      viewer().panEnabled,
      isFalse,
      reason: 'in draw mode one finger must ink, not pan',
    );
    expect(
      viewer().scaleEnabled,
      isTrue,
      reason: 'two-finger zoom stays available while drawing',
    );

    await unmount(tester);
  });

  testWidgets('ink and text scroll together on the canvas', (tester) async {
    // The ink layer used to be Positioned.fill over a separately scrolling
    // ListView, so scrolling the text slid it out from under its own ink.
    // One shared canvas means they move as one.
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
        of: find.byKey(const ValueKey('notebook-canvas-viewer')),
        matching: find.byType(NotebookInkCanvas),
      ),
      findsOneWidget,
      reason: 'the ink must live inside the pannable canvas',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notebook-canvas-viewer')),
        matching: find.byKey(const ValueKey('notebook-text-row-b1')),
      ),
      findsOneWidget,
      reason: 'text blocks must live on that same canvas',
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
}

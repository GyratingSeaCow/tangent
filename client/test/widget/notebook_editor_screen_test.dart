// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/widgets/dump_picker_sheet.dart';
import 'package:tangent/widgets/notebook_dump_card.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

/// T4: the notebook editor — text/checkbox blocks over a draggable dump-card
/// layer under an ink canvas, a page-local pen toolbar, and an explicit save.

DumpRow _dumpRow(String id, String title) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 17, 8),
      updatedAt: DateTime.utc(2026, 9, 17, 8),
      mode: 'brain_dump',
      durationSeconds: 95,
      title: title,
      audioPath: '/audio/$id.m4a',
      audioSizeBytes: 2048,
      syncStatus: 'local_only',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookRepository repository;

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

  testWidgets('Add text and Add checkbox append new blocks', (tester) async {
    await mountEditor(tester, notebook: testNotebook(id: 'nb-1'));

    expect(textBlocks(), findsNothing);

    await tester.tap(find.text('Add text'));
    await tester.pump();
    await tester.tap(find.text('Add checkbox'));
    await tester.pump();

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

    await tester.tap(find.text('Add recordings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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
}

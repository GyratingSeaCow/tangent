// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Imported images on the notebook page: tap-to-select highlight, drag the
// middle to move, edge tabs to resize with the aspect ratio locked, remove
// via the ×, and round-tripping geometry through save.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/widgets/notebook_image_block.dart';

import '../support/fake_notebook_repository.dart';

/// A 1x1 transparent PNG: a real decodable image, small enough to inline.
const String kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

NotebookImageBlock imageBlock({
  String id = 'img-1',
  double x = 100,
  double y = 200,
  double width = 200,
  double height = 100,
}) =>
    NotebookImageBlock(
      id: id,
      data: kTinyPngBase64,
      mime: 'image/png',
      x: x,
      y: y,
      width: width,
      height: height,
    );

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
  final List<Notebook> published = <Notebook>[];
  setUp(published.clear);

  Future<void> mountEditor(
    WidgetTester tester, {
    required Notebook notebook,
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
            _RecordingNotebookPersistence(repository, published),
          ),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
        ],
        child: MaterialApp(
          home: NotebookEditorScreen(notebookId: notebook.id),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
  }

  NotebookImageBlock savedImage() {
    expect(published, isNotEmpty, reason: 'save must publish the notebook');
    return published.last.document.blocks.single as NotebookImageBlock;
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save notebook'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('an image block renders and tap selects it with a highlight',
      (WidgetTester tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(blocks: <NotebookBlock>[imageBlock()]),
    );

    expect(find.byKey(const ValueKey('notebook-image-img-1')), findsOneWidget);
    // No chrome before selection.
    expect(
      find.byKey(const ValueKey('notebook-image-selected-img-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notebook-image-tab-left-img-1')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('notebook-image-img-1')));
    await tester.pump();

    // Selection highlight plus all four tabs and the remove control.
    expect(
      find.byKey(const ValueKey('notebook-image-selected-img-1')),
      findsOneWidget,
    );
    for (final String side in <String>['left', 'right', 'top', 'bottom']) {
      expect(
        find.byKey(ValueKey<String>('notebook-image-tab-$side-img-1')),
        findsOneWidget,
        reason: 'the $side resize tab belongs to the selection chrome',
      );
    }
    expect(
      find.byKey(const ValueKey('notebook-image-remove-img-1')),
      findsOneWidget,
    );
  });

  testWidgets('dragging the middle moves the image and save persists it',
      (WidgetTester tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(blocks: <NotebookBlock>[imageBlock()]),
    );
    await tester.tap(find.byKey(const ValueKey('notebook-image-img-1')));
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('notebook-image-img-1')),
      const Offset(60, 40),
    );
    await tester.pump();

    await save(tester);
    final NotebookImageBlock moved = savedImage();
    expect(moved.x, closeTo(160, 1));
    expect(moved.y, closeTo(240, 1));
    expect(moved.width, 200, reason: 'moving must not resize');
    expect(moved.height, 100, reason: 'moving must not resize');
    expect(moved.data, kTinyPngBase64, reason: 'moving must not touch bytes');
  });

  testWidgets('dragging the right tab resizes with the aspect ratio locked',
      (WidgetTester tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(blocks: <NotebookBlock>[imageBlock()]),
    );
    await tester.tap(find.byKey(const ValueKey('notebook-image-img-1')));
    await tester.pump();

    // 200x100 -> drag right edge +100 -> 300 wide; locked aspect (2:1)
    // makes it 150 tall. Anchored left edge: x stays.
    await tester.drag(
      find.byKey(const ValueKey('notebook-image-tab-right-img-1')),
      const Offset(100, 0),
    );
    await tester.pump();

    await save(tester);
    final NotebookImageBlock resized = savedImage();
    expect(resized.width, closeTo(300, 1));
    expect(resized.height, closeTo(150, 1), reason: 'aspect ratio is locked');
    expect(resized.x, closeTo(100, 1), reason: 'right-tab keeps left edge');
    expect(resized.y, closeTo(200, 1));
  });

  testWidgets('dragging the left tab anchors the right edge',
      (WidgetTester tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(blocks: <NotebookBlock>[imageBlock()]),
    );
    await tester.tap(find.byKey(const ValueKey('notebook-image-img-1')));
    await tester.pump();

    // Dragging the left tab left by 100 grows width to 300; the right edge
    // (x=300) must hold, so x becomes 0.
    await tester.drag(
      find.byKey(const ValueKey('notebook-image-tab-left-img-1')),
      const Offset(-100, 0),
    );
    await tester.pump();

    await save(tester);
    final NotebookImageBlock resized = savedImage();
    expect(resized.width, closeTo(300, 1));
    expect(resized.height, closeTo(150, 1), reason: 'aspect ratio is locked');
    expect(
      resized.x + resized.width,
      closeTo(300, 1),
      reason: 'left-tab resize keeps the right edge anchored',
    );
  });

  testWidgets('a tab drag cannot shrink the image below the usable floor',
      (WidgetTester tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(blocks: <NotebookBlock>[imageBlock()]),
    );
    await tester.tap(find.byKey(const ValueKey('notebook-image-img-1')));
    await tester.pump();

    // Far past zero: without the floor this would invert the rectangle.
    await tester.drag(
      find.byKey(const ValueKey('notebook-image-tab-right-img-1')),
      const Offset(-1000, 0),
    );
    await tester.pump();

    await save(tester);
    final NotebookImageBlock resized = savedImage();
    expect(resized.width, kMinNotebookImageWidth);
    expect(resized.height, kMinNotebookImageWidth / 2);
  });

  testWidgets('the remove control deletes the image block',
      (WidgetTester tester) async {
    await mountEditor(
      tester,
      notebook: testNotebook(blocks: <NotebookBlock>[imageBlock()]),
    );
    await tester.tap(find.byKey(const ValueKey('notebook-image-img-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notebook-image-remove-img-1')));
    await tester.pump();

    expect(find.byKey(const ValueKey('notebook-image-img-1')), findsNothing);

    await save(tester);
    expect(published.last.document.blocks, isEmpty);
  });

  testWidgets('image geometry survives a save/load round trip',
      (WidgetTester tester) async {
    final Notebook notebook =
        testNotebook(blocks: <NotebookBlock>[imageBlock()]);
    // The whole notebook file round-trips through the durable codec with the
    // image block intact — bytes, mime, and geometry.
    final String encoded = encodeNotebookFile(notebook);
    final Notebook decoded = decodeNotebookFile(encoded);
    final NotebookImageBlock block =
        decoded.document.blocks.single as NotebookImageBlock;
    expect(block.data, kTinyPngBase64);
    expect(block.mime, 'image/png');
    expect(block.x, 100);
    expect(block.y, 200);
    expect(block.width, 200);
    expect(block.height, 100);
    // The bytes decode to a real image.
    expect(base64Decode(block.data), isNotEmpty);
  });
}

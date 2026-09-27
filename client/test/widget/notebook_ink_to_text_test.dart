// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Ink to text (v1.21.0): the lasso row's Convert-to-text action.
//
// K1 (replace in place): the recognized text lands as ONE NotebookTextBlock
// at the lassoed ink's union-bbox top-left and the strokes are removed, as a
// single undoable step — one undo restores the ink AND removes the block,
// one redo re-applies both. Every failure path (transport error, 409
// not-installed, empty recognition) leaves the page exactly as it was.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart' show DumpRow;
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';
import 'package:tangent/screens/settings/handwriting_search_section.dart'
    show ocrSettingsClientProvider;
import 'package:tangent/services/notebook_persistence.dart';
import 'package:tangent/services/ocr_settings_client.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

import '../support/fake_notebook_repository.dart';

/// Save seam, so the replace test's save lands in [FakeNotebookRepository]
/// without touching the real storage backend (the same override
/// _RecordingNotebookPersistence provides in notebook_editor_screen_test).
class _StubNotebookPersistence implements NotebookPersistence {
  _StubNotebookPersistence(this._repository);

  final NotebookRepository _repository;

  @override
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await _repository.saveNotebook(notebook);
    return notebook;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A recognize seam: the editor's conversion posts through
/// [ocrSettingsClientProvider], so overriding that provider with this fake
/// puts the server's answer (or refusal) under test control — the same
/// override pattern _RecordingNotebookPersistence uses for saves.
class _FakeOcrClient extends OcrSettingsClient {
  _FakeOcrClient(this._handler) : super(baseUrl: 'http://fake.invalid');

  final Future<List<OcrRecognizedLine>> Function(
    List<Map<String, dynamic>> strokes,
  ) _handler;

  /// Every strokes payload posted, so a test can prove exactly the selected
  /// ink (and nothing else) reached the server.
  final List<List<Map<String, dynamic>>> posted =
      <List<Map<String, dynamic>>>[];

  @override
  Future<List<OcrRecognizedLine>> recognize(
    List<Map<String, dynamic>> strokes,
  ) {
    posted.add(strokes);
    return _handler(strokes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Two short strokes near canonical (100..120, 100) — the same geometry the
  // canvas lasso tests use, well inside the loop drawn by [lassoAroundInk].
  const InkStroke strokeA = InkStroke(
    id: 'ink-a',
    width: 4,
    points: <InkPoint>[
      InkPoint(x: 100, y: 100),
      InkPoint(x: 120, y: 100),
    ],
  );
  const InkStroke strokeB = InkStroke(
    id: 'ink-b',
    width: 4,
    points: <InkPoint>[
      InkPoint(x: 100, y: 115),
      InkPoint(x: 120, y: 115),
    ],
  );

  late FakeNotebookRepository repository;

  Notebook inkNotebook({List<NotebookBlock> blocks = const <NotebookBlock>[]}) =>
      testNotebook(
        id: 'nb-ink',
        title: 'Field notes',
        blocks: blocks,
        strokes: const <InkStroke>[strokeA, strokeB],
      );

  Future<void> mountEditor(
    WidgetTester tester, {
    required Notebook notebook,
    required _FakeOcrClient ocr,
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
            _StubNotebookPersistence(repository),
          ),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(const <DumpRow>[]),
          ),
          ocrSettingsClientProvider.overrideWith((ref) async => ocr),
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

  Future<void> enterLasso(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.draw));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('notebook-lasso')));
    await tester.pump();
  }

  Offset canvasOrigin(WidgetTester tester) => tester.getTopLeft(
        find.byKey(NotebookInkCanvas.backgroundKey),
      );

  /// Draws a loop around both seeded strokes.
  Future<void> lassoAroundInk(WidgetTester tester) async {
    final Offset origin = canvasOrigin(tester);
    final TestGesture g = await tester.createGesture();
    await g.down(origin + const Offset(80, 80));
    await tester.pump();
    for (final Offset p in const <Offset>[
      Offset(140, 80),
      Offset(140, 135),
      Offset(80, 135),
      Offset(80, 85),
    ]) {
      await g.moveTo(origin + p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
  }

  NotebookInkCanvasState canvasState(WidgetTester tester) =>
      tester.state<NotebookInkCanvasState>(find.byType(NotebookInkCanvas));

  List<String> inkIds(WidgetTester tester) => <String>[
        for (final InkStroke s in canvasState(tester).strokes) s.id,
      ];

  Finder convertButton() =>
      find.byKey(const ValueKey<String>('notebook-lasso-convert'));

  Finder deleteButton() =>
      find.byKey(const ValueKey<String>('notebook-lasso-delete'));

  VoidCallback? onPressedOf(WidgetTester tester, Finder button) =>
      tester.widget<IconButton>(button).onPressed;

  testWidgets('convert replaces the lassoed ink with one text block '
      'at the recognized bbox origin', (WidgetTester tester) async {
    final _FakeOcrClient ocr = _FakeOcrClient(
      (_) async => const <OcrRecognizedLine>[
        OcrRecognizedLine(
          text: 'hello world',
          strokeIds: <String>['ink-a'],
          bbox: Rect.fromLTRB(100, 100, 120, 104),
        ),
        OcrRecognizedLine(
          text: 'second line',
          strokeIds: <String>['ink-b'],
          bbox: Rect.fromLTRB(100, 115, 120, 119),
        ),
      ],
    );
    await mountEditor(tester, notebook: inkNotebook(), ocr: ocr);
    await enterLasso(tester);

    expect(
      onPressedOf(tester, convertButton()),
      isNull,
      reason: 'nothing selected yet: convert must be greyed',
    );

    await lassoAroundInk(tester);
    expect(onPressedOf(tester, convertButton()), isNotNull);

    await tester.tap(convertButton());
    await tester.pumpAndSettle();

    expect(
      ocr.posted.single.map((m) => m['id']),
      <String>['ink-a', 'ink-b'],
      reason: 'exactly the selected strokes are posted, in page order',
    );
    expect(
      inkIds(tester),
      isEmpty,
      reason: 'replace in place: the lassoed strokes are removed',
    );
    expect(
      find.text('hello world\nsecond line'),
      findsOneWidget,
      reason: 'one block, lines joined with newline',
    );

    // The block persists with the union bbox top-left and no stamps.
    await tester.tap(find.byIcon(Icons.save));
    await tester.pump();
    final Notebook saved = repository.saved.single;
    final NotebookTextBlock block =
        saved.document.blocks.whereType<NotebookTextBlock>().single;
    expect(block.text, 'hello world\nsecond line');
    expect(block.x, 100);
    expect(block.y, 100);
    expect(block.stamps, isEmpty);
  });

  testWidgets('one undo restores ink AND removes the block; '
      'redo round-trips; undo again', (WidgetTester tester) async {
    final _FakeOcrClient ocr = _FakeOcrClient(
      (_) async => const <OcrRecognizedLine>[
        OcrRecognizedLine(
          text: 'ping pong',
          strokeIds: <String>['ink-a', 'ink-b'],
          bbox: Rect.fromLTRB(100, 100, 120, 119),
        ),
      ],
    );
    await mountEditor(tester, notebook: inkNotebook(), ocr: ocr);
    await enterLasso(tester);
    await lassoAroundInk(tester);
    await tester.tap(convertButton());
    await tester.pumpAndSettle();

    expect(inkIds(tester), isEmpty);
    expect(find.text('ping pong'), findsOneWidget);

    // Undo: the strokes come back AND the block goes, in one step.
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(
      inkIds(tester),
      containsAll(<String>['ink-a', 'ink-b']),
      reason: 'one undo restores the converted ink',
    );
    expect(
      find.text('ping pong'),
      findsNothing,
      reason: 'the same undo removes the inserted block',
    );

    // Redo: both halves re-apply.
    await tester.tap(find.byKey(const ValueKey<String>('notebook-redo')));
    await tester.pumpAndSettle();
    expect(inkIds(tester), isEmpty, reason: 'redo removes the ink again');
    expect(
      find.text('ping pong'),
      findsOneWidget,
      reason: 'redo re-inserts the block',
    );

    // And the redo re-armed undo: a second undo reverses both again.
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(inkIds(tester), containsAll(<String>['ink-a', 'ink-b']));
    expect(find.text('ping pong'), findsNothing);
  });

  testWidgets('a transport failure mutates nothing and shows the failure '
      'snackbar', (WidgetTester tester) async {
    final _FakeOcrClient ocr = _FakeOcrClient(
      (_) async => throw const ApiException(
        statusCode: 502,
        code: 'http_error',
        message: 'handwriting recognition failed',
      ),
    );
    await mountEditor(tester, notebook: inkNotebook(), ocr: ocr);
    await enterLasso(tester);
    await lassoAroundInk(tester);
    await tester.tap(convertButton());
    await tester.pumpAndSettle();

    expect(inkIds(tester), <String>['ink-a', 'ink-b']);
    expect(find.byType(TextField), findsNWidgets(1)); // the title only
    expect(find.textContaining('Could not convert ink'), findsOneWidget);
  });

  testWidgets('a 409 shows the server\'s not-installed wording, untouched',
      (WidgetTester tester) async {
    final _FakeOcrClient ocr = _FakeOcrClient(
      (_) async => throw const ApiException(
        statusCode: 409,
        code: 'http_error',
        message: 'OCR environment is not installed',
      ),
    );
    await mountEditor(tester, notebook: inkNotebook(), ocr: ocr);
    await enterLasso(tester);
    await lassoAroundInk(tester);
    await tester.tap(convertButton());
    await tester.pumpAndSettle();

    expect(inkIds(tester), <String>['ink-a', 'ink-b']);
    expect(
      find.text('OCR environment is not installed'),
      findsOneWidget,
      reason: "the server's detail is shown verbatim, never reworded",
    );
  });

  testWidgets('empty recognition shows No text recognized and mutates '
      'nothing', (WidgetTester tester) async {
    final _FakeOcrClient ocr =
        _FakeOcrClient((_) async => const <OcrRecognizedLine>[]);
    await mountEditor(tester, notebook: inkNotebook(), ocr: ocr);
    await enterLasso(tester);
    await lassoAroundInk(tester);
    await tester.tap(convertButton());
    await tester.pumpAndSettle();

    expect(inkIds(tester), <String>['ink-a', 'ink-b']);
    expect(find.text('No text recognized'), findsOneWidget);
    // The selection survives an empty answer: nothing consumed it.
    expect(canvasState(tester).selectedCount, 2);
  });

  testWidgets('a blocks-only selection greys convert but leaves delete armed',
      (WidgetTester tester) async {
    final _FakeOcrClient ocr =
        _FakeOcrClient((_) async => const <OcrRecognizedLine>[]);
    // A placed text row far from the seeded ink, so a loop around it
    // catches the block and no strokes.
    await mountEditor(
      tester,
      notebook: inkNotebook(
        blocks: const <NotebookBlock>[
          NotebookTextBlock(id: 'tb', text: 'typed already', x: 100, y: 500),
        ],
      ),
      ocr: ocr,
    );
    await enterLasso(tester);

    final Offset origin = canvasOrigin(tester);
    final TestGesture g = await tester.createGesture();
    await g.down(origin + const Offset(60, 460));
    await tester.pump();
    for (final Offset p in const <Offset>[
      Offset(760, 460),
      Offset(760, 590),
      Offset(60, 590),
      Offset(60, 465),
    ]) {
      await g.moveTo(origin + p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();

    expect(
      onPressedOf(tester, deleteButton()),
      isNotNull,
      reason: 'the blocks-only catch is a live selection',
    );
    expect(
      convertButton(),
      findsOneWidget,
      reason: 'greyed, not hidden',
    );
    expect(
      onPressedOf(tester, convertButton()),
      isNull,
      reason: 'typed blocks are already text: nothing to convert',
    );
  });
}

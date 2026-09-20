// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The smart lasso.
//
// Lasso mode turns pointer input into a selection tool: circle ink to select
// every stroke inside the loop, drag anywhere within the selection to move it
// all, and delete it from the toolbar. Selection actions are single-undo
// operations, reusing the eraser's snapshot slot, so the existing undo button
// recovers a bad move or delete in one tap.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

void main() {
  const InkStroke strokeA = InkStroke(
    id: 'a',
    width: 4,
    points: <InkPoint>[
      InkPoint(x: 100, y: 100),
      InkPoint(x: 120, y: 100),
    ],
  );
  const InkStroke strokeB = InkStroke(
    id: 'b',
    width: 4,
    points: <InkPoint>[
      InkPoint(x: 300, y: 300),
      InkPoint(x: 320, y: 300),
    ],
  );

  final GlobalKey<NotebookInkCanvasState> canvasKey =
      GlobalKey<NotebookInkCanvasState>();

  Future<void> mount(
    WidgetTester tester, {
    required List<InkStroke> captured,
    required List<bool> selectionEvents,
    bool lassoing = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotebookInkCanvas(
            key: canvasKey,
            strokes: const <InkStroke>[strokeA, strokeB],
            drawingEnabled: true,
            erasing: false,
            lassoing: lassoing,
            penWidth: 4,
            opaqueBackground: false,
            onSelectionChanged: selectionEvents.add,
            onStrokesChanged: (List<InkStroke> s) {
              captured
                ..clear()
                ..addAll(s);
            },
          ),
        ),
      ),
    );
  }

  /// Drags a closed loop around stroke A.
  Future<void> lassoAroundA(WidgetTester tester) async {
    final TestGesture g = await tester.createGesture();
    await g.down(const Offset(80, 80));
    await tester.pump();
    for (final Offset p in const <Offset>[
      Offset(140, 80),
      Offset(140, 130),
      Offset(80, 130),
      Offset(80, 85),
    ]) {
      await g.moveTo(p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
  }

  testWidgets('circling a stroke selects it and only it',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);

    await lassoAroundA(tester);

    expect(selection, isNotEmpty);
    expect(selection.last, isTrue);
    expect(canvasKey.currentState!.selectedCount, 1);
    expect(
      captured,
      isEmpty,
      reason: 'a lasso is a selection, never a stroke',
    );
  });

  testWidgets('deleting the selection removes it; undo brings it back',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);

    await lassoAroundA(tester);
    final bool deleted = canvasKey.currentState!.deleteSelection();
    await tester.pump();

    expect(deleted, isTrue);
    expect(
      captured.map((s) => s.id),
      <String>['b'],
      reason: 'only the circled stroke goes',
    );
    expect(selection.last, isFalse, reason: 'nothing is selected afterwards');

    canvasKey.currentState!.undoLastStroke();
    await tester.pump();
    expect(
      captured.map((s) => s.id),
      containsAll(<String>['a', 'b']),
      reason: 'one undo restores the whole delete',
    );
  });

  testWidgets('dragging inside the selection moves every selected stroke',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);

    await lassoAroundA(tester);

    // Drag from within the selection to elsewhere on the page.
    final TestGesture g = await tester.createGesture();
    await g.down(const Offset(110, 100));
    await tester.pump();
    await g.moveTo(const Offset(160, 160));
    await tester.pump();
    await g.up();
    await tester.pump();

    final InkStroke moved = captured.singleWhere((InkStroke s) => s.id == 'a');
    expect(moved.points.first.x, closeTo(150, 0.001));
    expect(moved.points.first.y, closeTo(160, 0.001));
    final InkStroke untouched =
        captured.singleWhere((InkStroke s) => s.id == 'b');
    expect(
      untouched.points.first.x,
      300,
      reason: 'unselected ink must not move',
    );

    canvasKey.currentState!.undoLastStroke();
    await tester.pump();
    expect(
      captured.singleWhere((InkStroke s) => s.id == 'a').points.first.x,
      100,
      reason: 'one undo restores the original position',
    );
  });

  testWidgets('lassoing empty page clears the selection',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);

    await lassoAroundA(tester);
    expect(selection.last, isTrue);

    // A loop around nothing, far from both strokes.
    final TestGesture g = await tester.createGesture();
    await g.down(const Offset(500, 500));
    await tester.pump();
    for (final Offset p in const <Offset>[
      Offset(560, 500),
      Offset(560, 560),
      Offset(500, 560),
      Offset(500, 505),
    ]) {
      await g.moveTo(p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();

    expect(selection.last, isFalse);
    expect(canvasKey.currentState!.selectedCount, 0);
  });

  testWidgets('leaving lasso mode clears the selection',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);
    await lassoAroundA(tester);
    expect(selection.last, isTrue);

    await mount(
      tester,
      captured: captured,
      selectionEvents: selection,
      lassoing: false,
    );
    await tester.pump();

    expect(selection.last, isFalse);
    expect(
      canvasKey.currentState!.selectedCount,
      0,
      reason: 'a stale selection must not survive the mode',
    );
  });

  testWidgets('a cancelled gesture does not wedge the lasso',
      (WidgetTester tester) async {
    // The latch bug: a PointerCancel (system gesture, palm claim, second
    // finger) used to leave _activePointer set, silently killing every
    // later lasso gesture on the page.
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);

    final TestGesture doomed = await tester.createGesture();
    await doomed.down(const Offset(80, 80));
    await tester.pump();
    await doomed.moveTo(const Offset(140, 80));
    await tester.pump();
    await doomed.cancel();
    await tester.pump();

    // The next loop must work exactly as if the cancelled one never was.
    await lassoAroundA(tester);
    expect(
      selection,
      isNotEmpty,
      reason: 'a cancelled gesture must release the pointer latch',
    );
    expect(selection.last, isTrue);
    expect(canvasKey.currentState!.selectedCount, 1);
  });

  testWidgets('lasso mode never inks even over empty space',
      (WidgetTester tester) async {
    final List<InkStroke> captured = <InkStroke>[];
    final List<bool> selection = <bool>[];
    await mount(tester, captured: captured, selectionEvents: selection);

    final TestGesture g = await tester.createGesture();
    await g.down(const Offset(400, 150));
    await tester.pump();
    await g.moveTo(const Offset(450, 200));
    await tester.pump();
    await g.up();
    await tester.pump();

    expect(captured, isEmpty);
    expect(canvasKey.currentState!.strokes, hasLength(2));
  });

  group('external (block) selection', () {
    Future<void> mountWithBlocks(
      WidgetTester tester, {
      required List<bool> selectionEvents,
      required List<Offset> dragSteps,
      required List<List<Offset>> loops,
      int externalMatches = 1,
      bool Function(Offset)? hitsExternal,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotebookInkCanvas(
              key: canvasKey,
              // No strokes at all: the selection below is blocks-only.
              strokes: const <InkStroke>[],
              drawingEnabled: true,
              erasing: false,
              lassoing: true,
              penWidth: 4,
              opaqueBackground: false,
              onSelectionChanged: selectionEvents.add,
              onLassoLoop: (List<Offset> loop) {
                loops.add(List<Offset>.of(loop));
                return externalMatches;
              },
              hitsExternalSelection:
                  hitsExternal ?? (Offset p) => p.dx < 200 && p.dy < 200,
              onSelectionDragStep: dragSteps.add,
              onStrokesChanged: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('a loop that catches only blocks still counts as a selection',
        (WidgetTester tester) async {
      final List<bool> selection = <bool>[];
      final List<Offset> steps = <Offset>[];
      final List<List<Offset>> loops = <List<Offset>>[];
      await mountWithBlocks(
        tester,
        selectionEvents: selection,
        dragSteps: steps,
        loops: loops,
      );

      await lassoAroundA(tester);

      expect(
        loops,
        hasLength(1),
        reason: 'the completed loop is reported outward',
      );
      expect(
        selection.last,
        isTrue,
        reason: 'blocks-only selections must enable the delete action',
      );
    });

    testWidgets('dragging a blocks-only selection reports its deltas',
        (WidgetTester tester) async {
      final List<bool> selection = <bool>[];
      final List<Offset> steps = <Offset>[];
      final List<List<Offset>> loops = <List<Offset>>[];
      await mountWithBlocks(
        tester,
        selectionEvents: selection,
        dragSteps: steps,
        loops: loops,
      );

      await lassoAroundA(tester);
      // Drag from inside the external selection's claimed area.
      final TestGesture g = await tester.createGesture();
      await g.down(const Offset(100, 100));
      await tester.pump();
      await g.moveTo(const Offset(150, 130));
      await tester.pump();
      await g.up();
      await tester.pump();

      final Offset total =
          steps.fold(Offset.zero, (Offset a, Offset b) => a + b);
      expect(total.dx, closeTo(50, 0.001));
      expect(total.dy, closeTo(30, 0.001));
    });

    testWidgets('clearSelection empties the selection and says so',
        (WidgetTester tester) async {
      final List<bool> selection = <bool>[];
      await mountWithBlocks(
        tester,
        selectionEvents: selection,
        dragSteps: <Offset>[],
        loops: <List<Offset>>[],
      );

      await lassoAroundA(tester);
      expect(selection.last, isTrue);

      canvasKey.currentState!.clearSelection();
      await tester.pump();
      expect(selection.last, isFalse);
    });
  });
}

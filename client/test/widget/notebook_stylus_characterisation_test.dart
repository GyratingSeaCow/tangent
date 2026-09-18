// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

/// Characterisation: what does the canvas do with a stylus TODAY?
///
/// `_acceptsDevice` documents "stylus input is always honoured", but the
/// pointer handler returns early on `!drawingEnabled` and the whole canvas is
/// wrapped in IgnorePointer, so the claim may not hold. These tests record the
/// real behaviour before anything changes.
void main() {
  Future<List<InkStroke>> draw(
    WidgetTester tester, {
    required bool drawingEnabled,
    required PointerDeviceKind kind,
  }) async {
    List<InkStroke> captured = const <InkStroke>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: NotebookInkCanvas(
              strokes: const <InkStroke>[],
              drawingEnabled: drawingEnabled,
              erasing: false,
              penWidth: 3,
              onStrokesChanged: (s) => captured = s,
            ),
          ),
        ),
      ),
    );

    final TestGesture gesture =
        await tester.createGesture(kind: kind, pointer: 1);
    await gesture.down(const Offset(100, 100));
    await tester.pump();
    await gesture.moveTo(const Offset(140, 140));
    await tester.pump();
    await gesture.moveTo(const Offset(180, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    return captured;
  }

  group('stylus on the notebook canvas', () {
    testWidgets('stylus draws when draw mode is ON', (tester) async {
      final strokes = await draw(
        tester,
        drawingEnabled: true,
        kind: PointerDeviceKind.stylus,
      );
      expect(strokes, isNotEmpty);
    });

    testWidgets('stylus with draw mode OFF — writes', (tester) async {
      final strokes = await draw(
        tester,
        drawingEnabled: false,
        kind: PointerDeviceKind.stylus,
      );
      // This file characterised the pre-change behaviour and recorded that the
      // pen was ignored without draw mode, flagging it as the thing to fix.
      // The fix landed: _acceptsDevice's doc comment is now true, because the
      // blanket `!drawingEnabled` early return that made its stylus branch
      // dead code is gone.
      expect(
        strokes,
        isNotEmpty,
        reason: 'the pen writes with no mode toggle -- the change this file '
            'was written to make visible',
      );
    });

    testWidgets('finger with draw mode OFF does not draw', (tester) async {
      final strokes = await draw(
        tester,
        drawingEnabled: false,
        kind: PointerDeviceKind.touch,
      );
      expect(strokes, isEmpty);
    });
  });
}

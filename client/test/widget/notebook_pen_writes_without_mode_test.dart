// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pen writes without draw mode; finger keeps behaving as it always did.
//
// On an active-pen device, requiring a mode toggle before writing is the
// single largest friction in a handwriting app. The pen should ink wherever it
// touches the page, and the draw-mode button becomes a backup for finger
// writing rather than the way handwriting is reached.
//
// The hard part is not "let the stylus draw" -- it is letting the FINGER keep
// working. The ink canvas is a Positioned.fill layer sitting on top of every
// text box, checkbox and recording card in the editor, so anything it
// swallows becomes unreachable. These tests pin both halves.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

void main() {
  /// Mounts the canvas over a tappable target, exactly as the editor stacks it
  /// over its blocks.
  Future<void> mountOverTarget(
    WidgetTester tester, {
    required bool drawingEnabled,
    required List<InkStroke> captured,
    required List<String> tapped,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => tapped.add('below'),
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned.fill(
                  child: NotebookInkCanvas(
                    strokes: const <InkStroke>[],
                    drawingEnabled: drawingEnabled,
                    erasing: false,
                    penWidth: 3,
                    opaqueBackground: false,
                    onStrokesChanged: (List<InkStroke> s) {
                      captured
                        ..clear()
                        ..addAll(s);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> strokeWith(
    WidgetTester tester,
    PointerDeviceKind kind, {
    int buttons = 0,
  }) async {
    final TestGesture gesture = await tester.createGesture(
      kind: kind,
      pointer: 1,
      buttons: buttons,
    );
    await gesture.down(const Offset(100, 100));
    await tester.pump();
    await gesture.moveTo(const Offset(140, 140));
    await tester.pump();
    await gesture.moveTo(const Offset(180, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('pen writes without draw mode', () {
    testWidgets('a pen inks with draw mode OFF', (WidgetTester tester) async {
      final List<InkStroke> captured = <InkStroke>[];
      final List<String> tapped = <String>[];
      await mountOverTarget(
        tester,
        drawingEnabled: false,
        captured: captured,
        tapped: tapped,
      );

      await strokeWith(tester, PointerDeviceKind.stylus);

      expect(
        captured,
        isNotEmpty,
        reason: 'the pen must write wherever it touches the page, with no '
            'mode toggle first',
      );
    });

    testWidgets('a pen stroke does not also reach the widgets below',
        (WidgetTester tester) async {
      // If the canvas merely passed everything through, a pen stroke across a
      // text box would ink AND drag the box at the same time.
      final List<InkStroke> captured = <InkStroke>[];
      final List<String> tapped = <String>[];
      await mountOverTarget(
        tester,
        drawingEnabled: false,
        captured: captured,
        tapped: tapped,
      );

      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 1,
      );
      await gesture.down(const Offset(100, 100));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tapped,
        isEmpty,
        reason: 'the pen belongs to the ink layer; the block underneath must '
            'not receive the same gesture',
      );
    });

    testWidgets('a finger does NOT ink with draw mode OFF',
        (WidgetTester tester) async {
      final List<InkStroke> captured = <InkStroke>[];
      final List<String> tapped = <String>[];
      await mountOverTarget(
        tester,
        drawingEnabled: false,
        captured: captured,
        tapped: tapped,
      );

      await strokeWith(tester, PointerDeviceKind.touch);

      expect(
        captured,
        isEmpty,
        reason: 'a finger scrolls and taps; only the pen writes by default',
      );
    });

    testWidgets('a finger still reaches the widgets below with draw mode OFF',
        (WidgetTester tester) async {
      // The regression that would matter most: the ink layer covers every
      // block in the editor, so swallowing touch makes text boxes, checkboxes
      // and recording cards untappable.
      final List<InkStroke> captured = <InkStroke>[];
      final List<String> tapped = <String>[];
      await mountOverTarget(
        tester,
        drawingEnabled: false,
        captured: captured,
        tapped: tapped,
      );

      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(
        tapped,
        <String>['below'],
        reason: 'touch must fall through the ink layer to the blocks',
      );
    });

    testWidgets('draw mode ON still lets a finger write',
        (WidgetTester tester) async {
      // The button stays useful as a backup for finger writing.
      final List<InkStroke> captured = <InkStroke>[];
      final List<String> tapped = <String>[];
      await mountOverTarget(
        tester,
        drawingEnabled: true,
        captured: captured,
        tapped: tapped,
      );

      await strokeWith(tester, PointerDeviceKind.touch);

      expect(captured, isNotEmpty, reason: 'draw mode is the finger backup');
    });

    testWidgets('draw mode ON takes touch away from the widgets below',
        (WidgetTester tester) async {
      final List<InkStroke> captured = <InkStroke>[];
      final List<String> tapped = <String>[];
      await mountOverTarget(
        tester,
        drawingEnabled: true,
        captured: captured,
        tapped: tapped,
      );

      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(
        tapped,
        isEmpty,
        reason: 'with draw mode on the canvas owns the page, or a finger '
            'stroke would also tap whatever it passes over',
      );
    });

    testWidgets('the side button erases with draw mode OFF',
        (WidgetTester tester) async {
      // The verified side-button eraser must keep working now that reaching
      // the canvas no longer requires draw mode.
      final List<InkStroke> captured = <InkStroke>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: NotebookInkCanvas(
                strokes: const <InkStroke>[
                  InkStroke(
                    id: 's1',
                    width: 3,
                    points: <InkPoint>[
                      InkPoint(x: 100, y: 100),
                      InkPoint(x: 180, y: 100),
                    ],
                  ),
                ],
                drawingEnabled: false,
                erasing: false,
                penWidth: 3,
                opaqueBackground: false,
                onStrokesChanged: (List<InkStroke> s) {
                  captured
                    ..clear()
                    ..addAll(s);
                },
              ),
            ),
          ),
        ),
      );

      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 1,
        buttons: kPrimaryStylusButton,
      );
      await gesture.down(const Offset(100, 60));
      await tester.pump();
      await gesture.moveTo(const Offset(140, 140));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        captured,
        isEmpty,
        reason: 'the side button must erase without draw mode too',
      );
    });
  });
}

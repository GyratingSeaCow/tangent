// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

// The pen's side button erases, without touching the eraser toggle.
//
// Measured on the Galaxy Tab S10 FE EMR digitizer: holding the side button
// delivers ordinary `stylus` events with `buttons == kPrimaryStylusButton`
// (2) on the down event, every move, and the up — the flag is present for the
// whole gesture, so the canvas can read it per-event without latching.
//
// Flip-to-erase is deliberately NOT built on `invertedStylus`: flipping this
// pen never produced that kind, so a gesture hung off it would silently do
// nothing.

InkStroke _horizontal(String id, double y) => InkStroke(
      id: id,
      width: 3,
      points: <InkPoint>[
        InkPoint(x: 20, y: y),
        InkPoint(x: 100, y: y),
        InkPoint(x: 180, y: y),
      ],
    );

void main() {
  late List<InkStroke> latest;

  Future<void> pump(
    WidgetTester tester,
    List<InkStroke> strokes, {
    bool erasing = false,
  }) async {
    latest = strokes;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: NotebookInkCanvas(
              strokes: strokes,
              drawingEnabled: true,
              penWidth: 3,
              erasing: erasing,
              onStrokesChanged: (List<InkStroke> s) => latest = s,
            ),
          ),
        ),
      ),
    );
  }

  group('stylus side button erases', () {
    testWidgets('tapping a line with the button held erases it', (tester) async {
      await pump(tester, <InkStroke>[
        _horizontal('top', 60),
        _horizontal('middle', 150),
        _horizontal('bottom', 240),
      ]);

      final TestGesture pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );
      await pen.down(const Offset(100, 150));
      await tester.pump();
      await pen.up();
      await tester.pumpAndSettle();

      expect(
        latest.map((InkStroke s) => s.id),
        <String>['top', 'bottom'],
        reason: 'the button-held pen must erase the line it touched',
      );
    });

    testWidgets('dragging with the button held erases along the path',
        (tester) async {
      await pump(tester, <InkStroke>[
        _horizontal('top', 60),
        _horizontal('middle', 150),
        _horizontal('bottom', 240),
      ]);

      final TestGesture pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );
      await pen.down(const Offset(100, 55));
      await tester.pump();
      for (double y = 60; y <= 155; y += 5) {
        await pen.moveTo(Offset(100, y));
        await tester.pump();
      }
      await pen.up();
      await tester.pumpAndSettle();

      expect(
        latest.map((InkStroke s) => s.id),
        <String>['bottom'],
        reason: 'a swept button-held drag erases every line it crosses',
      );
    });

    testWidgets('erasing happens DURING the drag, not only on lift',
        (tester) async {
      // Down on empty space, sweep across the line, then return to the start
      // and lift there. The up-handler only sweeps from the last recorded
      // erase position, so if move events are ignored the round trip ends
      // where it began and the line survives. This is what proves the move
      // branch carries the button-held gesture.
      await pump(tester, <InkStroke>[_horizontal('middle', 150)]);

      final TestGesture pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );
      await pen.down(const Offset(100, 40));
      await tester.pump();
      for (double y = 45; y <= 200; y += 5) {
        await pen.moveTo(Offset(100, y));
        await tester.pump();
      }
      for (double y = 195; y >= 40; y -= 5) {
        await pen.moveTo(Offset(100, y));
        await tester.pump();
      }
      await pen.up();
      await tester.pumpAndSettle();

      expect(
        latest,
        isEmpty,
        reason: 'the line under the swept path must be gone',
      );
    });

    testWidgets('the button does NOT leave ink behind', (tester) async {
      await pump(tester, const <InkStroke>[]);

      final TestGesture pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );
      await pen.down(const Offset(40, 40));
      await tester.pump();
      await pen.moveTo(const Offset(120, 120));
      await tester.pump();
      await pen.up();
      await tester.pumpAndSettle();

      expect(latest, isEmpty, reason: 'erasing must never draw');
    });

    testWidgets('without the button the pen still draws', (tester) async {
      await pump(tester, const <InkStroke>[]);

      final TestGesture pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
      );
      await pen.down(const Offset(40, 40));
      await tester.pump();
      await pen.moveTo(const Offset(120, 120));
      await tester.pump();
      await pen.up();
      await tester.pumpAndSettle();

      expect(latest, hasLength(1));
    });

    testWidgets('a finger with the primary button still draws', (tester) async {
      // Touch always reports buttons==1; only the STYLUS button means erase,
      // so a finger must be unaffected by the new branch.
      await pump(tester, const <InkStroke>[]);

      final TestGesture finger = await tester.createGesture(
        kind: PointerDeviceKind.touch,
      );
      await finger.down(const Offset(40, 40));
      await tester.pump();
      await finger.moveTo(const Offset(120, 120));
      await tester.pump();
      await finger.up();
      await tester.pumpAndSettle();

      expect(latest, hasLength(1));
    });

    testWidgets('the eraser toggle still erases without any button',
        (tester) async {
      await pump(
        tester,
        <InkStroke>[_horizontal('only', 150)],
        erasing: true,
      );

      final TestGesture pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
      );
      await pen.down(const Offset(100, 150));
      await tester.pump();
      await pen.up();
      await tester.pumpAndSettle();

      expect(latest, isEmpty);
    });
  });
}

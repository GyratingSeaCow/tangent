// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

// The pen screen previously offered undo-last-stroke only, so correcting an
// early mistake meant destroying everything drawn after it. These pin the
// eraser Jeff asked for: tap a line to remove it, or drag across several.

InkStroke _line(String id, List<Offset> points) => InkStroke(
      id: id,
      width: 3,
      points: <InkPoint>[
        for (final p in points) InkPoint(x: p.dx, y: p.dy),
      ],
    );

/// A horizontal line at [y] spanning x=20..180.
InkStroke _horizontal(String id, double y) => _line(id, <Offset>[
      Offset(20, y),
      Offset(100, y),
      Offset(180, y),
    ]);

void main() {
  final key = GlobalKey<NotebookInkCanvasState>();
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
              key: key,
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

  group('stroke eraser', () {
    testWidgets('tapping a line erases that line only', (tester) async {
      // Three parallel lines; the user taps the middle one.
      await pump(
        tester,
        <InkStroke>[
          _horizontal('top', 40),
          _horizontal('middle', 100),
          _horizontal('bottom', 160),
        ],
        erasing: true,
      );

      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(
        latest.map((InkStroke s) => s.id),
        <String>['top', 'bottom'],
        reason: 'only the tapped line goes; the others are untouched',
      );
    });

    testWidgets('dragging across lines erases each one crossed',
        (tester) async {
      await pump(
        tester,
        <InkStroke>[
          _horizontal('top', 40),
          _horizontal('middle', 100),
          _horizontal('bottom', 160),
        ],
        erasing: true,
      );

      // A vertical drag down the middle crosses all three.
      final gesture = await tester.startGesture(const Offset(100, 20));
      await gesture.moveTo(const Offset(100, 60));
      await gesture.moveTo(const Offset(100, 120));
      await gesture.moveTo(const Offset(100, 180));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(latest, isEmpty, reason: 'the drag crossed every line');
    });

    testWidgets('tapping empty space erases nothing', (tester) async {
      await pump(
        tester,
        <InkStroke>[_horizontal('only', 100)],
        erasing: true,
      );

      await tester.tapAt(const Offset(100, 250));
      await tester.pumpAndSettle();

      expect(latest.map((InkStroke s) => s.id), <String>['only']);
    });

    testWidgets('a near miss still erases: thin lines need a tolerance band',
        (tester) async {
      // Exact-pixel hit testing on a 3px line is unusable with a fingertip.
      await pump(
        tester,
        <InkStroke>[_horizontal('only', 100)],
        erasing: true,
      );

      await tester.tapAt(const Offset(100, 106));
      await tester.pumpAndSettle();

      expect(latest, isEmpty, reason: '6px off must still count as a hit');
    });

    testWidgets('a far miss does not erase', (tester) async {
      await pump(
        tester,
        <InkStroke>[_horizontal('only', 100)],
        erasing: true,
      );

      await tester.tapAt(const Offset(100, 145));
      await tester.pumpAndSettle();

      expect(
        latest.map((InkStroke s) => s.id),
        <String>['only'],
        reason: 'the band must not be so wide that it erases by accident',
      );
    });

    testWidgets('erasing is undoable', (tester) async {
      await pump(
        tester,
        <InkStroke>[_horizontal('a', 60), _horizontal('b', 140)],
        erasing: true,
      );

      await tester.tapAt(const Offset(100, 60));
      await tester.pumpAndSettle();
      expect(latest.map((InkStroke s) => s.id), <String>['b']);

      key.currentState!.undoLastStroke();
      await tester.pumpAndSettle();

      expect(
        latest.map((InkStroke s) => s.id).toSet(),
        <String>{'a', 'b'},
        reason: 'an accidental erase must be recoverable',
      );
    });

    testWidgets('with the eraser off, drawing still works', (tester) async {
      await pump(tester, <InkStroke>[_horizontal('kept', 100)]);

      final gesture = await tester.startGesture(const Offset(40, 200));
      await gesture.moveTo(const Offset(120, 220));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        latest.length,
        2,
        reason: 'pen mode adds a stroke and never erases',
      );
    });

    testWidgets('one drag erasing several lines undoes as one action',
        (tester) async {
      // A single eraser stroke is one user action, so one undo restores it.
      await pump(
        tester,
        <InkStroke>[_horizontal('a', 60), _horizontal('b', 100)],
        erasing: true,
      );

      final gesture = await tester.startGesture(const Offset(100, 40));
      await gesture.moveTo(const Offset(100, 80));
      await gesture.moveTo(const Offset(100, 120));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(latest, isEmpty);

      key.currentState!.undoLastStroke();
      await tester.pumpAndSettle();

      expect(
        latest.map((InkStroke s) => s.id).toSet(),
        <String>{'a', 'b'},
        reason: 'one gesture is one undo step, not two',
      );
    });
  });
}

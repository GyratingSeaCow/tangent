// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

/// Test harness that owns the mutable inputs of [NotebookInkCanvas] so a test
/// can flip `penWidth` / `drawingEnabled` mid-session and rebuild.
class _CanvasHarness {
  _CanvasHarness({
    this.drawingEnabled = true,
    this.penWidth = 3,
    List<InkStroke>? initialStrokes,
  }) : strokes = initialStrokes ?? const <InkStroke>[];

  final GlobalKey<NotebookInkCanvasState> canvasKey =
      GlobalKey<NotebookInkCanvasState>();
  final List<List<InkStroke>> reports = <List<InkStroke>>[];

  bool drawingEnabled;
  double penWidth;
  List<InkStroke> strokes;
  late StateSetter _setState;

  NotebookInkCanvasState get state => canvasKey.currentState!;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  _setState = setState;
                  return NotebookInkCanvas(
                    key: canvasKey,
                    strokes: strokes,
                    drawingEnabled: drawingEnabled,
                    penWidth: penWidth,
                    onStrokesChanged: reports.add,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> setPenWidth(WidgetTester tester, double width) async {
    penWidth = width;
    _setState(() {});
    await tester.pump();
  }

}

Offset _at(WidgetTester tester, Offset local) =>
    tester.getTopLeft(find.byType(NotebookInkCanvas)) + local;

List<Offset> _offsetsOf(InkStroke stroke) =>
    stroke.points.map((InkPoint p) => Offset(p.x, p.y)).toList();

Future<void> _drawStroke(
  WidgetTester tester, {
  required List<Offset> path,
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) async {
  final TestGesture gesture =
      await tester.startGesture(_at(tester, path.first), kind: kind);
  await tester.pump();
  for (final Offset step in path.skip(1)) {
    await gesture.moveTo(_at(tester, step));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  group('InkStroke / InkPoint codecs', () {
    test('round-trips through JSON', () {
      const InkStroke stroke = InkStroke(
        id: 'stroke-1',
        width: 7.5,
        points: <InkPoint>[
          InkPoint(x: 1, y: 2),
          InkPoint(x: 3.5, y: 4.25),
        ],
      );

      final Map<String, dynamic> json = stroke.toJson();
      expect(json['id'], 'stroke-1');
      expect(json['width'], 7.5);
      expect(json['points'], isA<List<dynamic>>());

      final InkStroke decoded = InkStroke.fromJson(json);
      expect(decoded.id, 'stroke-1');
      expect(decoded.width, 7.5);
      expect(_offsetsOf(decoded), <Offset>[
        const Offset(1, 2),
        const Offset(3.5, 4.25),
      ]);
      expect(decoded, stroke);
    });

    test('InkPoint tolerates int-valued JSON numbers', () {
      final InkPoint point = InkPoint.fromJson(<String, dynamic>{'x': 4, 'y': 9});
      expect(point.x, 4.0);
      expect(point.y, 9.0);
      expect(point.toJson(), <String, dynamic>{'x': 4.0, 'y': 9.0});
    });
  });

  group('NotebookInkCanvas', () {
    testWidgets('paints white ink on a black background', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      expect(NotebookInkCanvas.inkColor, Colors.white);
      expect(NotebookInkCanvas.backgroundColor, Colors.black);

      final ColoredBox background = tester.widget<ColoredBox>(
        find.byKey(NotebookInkCanvas.backgroundKey),
      );
      expect(background.color, Colors.black);

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(NotebookInkCanvas),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(paint.painter, isA<NotebookInkPainter>());
    });

    testWidgets('stylus drag produces one stroke with the drawn points',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[
          const Offset(10, 10),
          const Offset(30, 10),
          const Offset(50, 40),
        ],
      );

      expect(harness.state.strokes, hasLength(1));
      final InkStroke stroke = harness.state.strokes.single;
      expect(_offsetsOf(stroke), <Offset>[
        const Offset(10, 10),
        const Offset(30, 10),
        const Offset(50, 40),
      ]);
      expect(stroke.width, 3.0);
      expect(stroke.id, isNotEmpty);
    });

    testWidgets('each completed stroke gets a fresh unique id', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(25, 5)],
      );
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 40), const Offset(25, 40)],
      );

      final List<InkStroke> strokes = harness.state.strokes;
      expect(strokes, hasLength(2));
      expect(strokes[0].id, isNot(strokes[1].id));
      expect(strokes[0].id.length, greaterThan(30));
    });

    testWidgets('touch drag produces NO stroke when drawingEnabled is false',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness(drawingEnabled: false);
      await harness.pump(tester);

      await _drawStroke(
        tester,
        kind: PointerDeviceKind.touch,
        path: <Offset>[
          const Offset(10, 10),
          const Offset(60, 60),
          const Offset(100, 90),
        ],
      );

      expect(harness.state.strokes, isEmpty);
      expect(harness.reports, isEmpty);
    });

    testWidgets('stylus drag produces NO stroke when drawingEnabled is false',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness(drawingEnabled: false);
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(10, 10), const Offset(60, 60)],
      );

      expect(harness.state.strokes, isEmpty);
      expect(harness.reports, isEmpty);
    });

    testWidgets('disabled canvas lets content beneath receive the gesture',
        (tester) async {
      int taps = 0;
      final GlobalKey<NotebookInkCanvasState> key =
          GlobalKey<NotebookInkCanvasState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () => taps++,
                        behavior: HitTestBehavior.opaque,
                      ),
                    ),
                    Positioned.fill(
                      child: NotebookInkCanvas(
                        key: key,
                        strokes: const <InkStroke>[],
                        drawingEnabled: false,
                        penWidth: 3,
                        onStrokesChanged: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tapAt(_at(tester, const Offset(40, 40)));
      await tester.pump();

      expect(taps, 1);
      expect(key.currentState!.strokes, isEmpty);
    });

    testWidgets('touch drag DOES produce a stroke when drawingEnabled is true',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        kind: PointerDeviceKind.touch,
        path: <Offset>[
          const Offset(12, 12),
          const Offset(40, 12),
        ],
      );

      expect(harness.state.strokes, hasLength(1));
      expect(_offsetsOf(harness.state.strokes.single), <Offset>[
        const Offset(12, 12),
        const Offset(40, 12),
      ]);
    });

    testWidgets('a tap with no movement still produces a dot stroke',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      final TestGesture gesture =
          await tester.startGesture(_at(tester, const Offset(20, 20)));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(harness.state.strokes, hasLength(1));
      final InkStroke dot = harness.state.strokes.single;
      expect(dot.points, hasLength(1));
      expect(_offsetsOf(dot).single, const Offset(20, 20));
      expect(harness.reports, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('pen width change does not mutate strokes already drawn',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(10, 10), const Offset(40, 10)],
      );
      expect(harness.state.strokes.single.width, 3.0);

      await harness.setPenWidth(tester, 18);
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(10, 60), const Offset(40, 60)],
      );

      expect(harness.state.strokes, hasLength(2));
      expect(
        harness.state.strokes[0].width,
        3.0,
        reason: 'earlier stroke must keep the width it was drawn with',
      );
      expect(harness.state.strokes[1].width, 18.0);
    });

    testWidgets('a stroke keeps the pen width active when it STARTED',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness(penWidth: 6);
      await harness.pump(tester);

      final TestGesture gesture =
          await tester.startGesture(_at(tester, const Offset(10, 10)));
      await tester.pump();
      await harness.setPenWidth(tester, 22);
      await gesture.moveTo(_at(tester, const Offset(60, 10)));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(harness.state.strokes.single.width, 6.0);
    });

    testWidgets('onStrokesChanged fires with the accumulated stroke list',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 30), const Offset(30, 30)],
      );

      expect(harness.reports, hasLength(2));
      expect(harness.reports[0], hasLength(1));
      expect(harness.reports[1], hasLength(2));
      expect(harness.reports[1].last.id, harness.state.strokes.last.id);
    });

    testWidgets('onStrokesChanged does not fire mid-stroke', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      final TestGesture gesture =
          await tester.startGesture(_at(tester, const Offset(10, 10)));
      await tester.pump();
      await gesture.moveTo(_at(tester, const Offset(40, 10)));
      await tester.pump();
      expect(harness.reports, isEmpty);

      await gesture.up();
      await tester.pump();
      expect(harness.reports, hasLength(1));
    });

    testWidgets('undoLastStroke removes the last stroke and reports',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 30), const Offset(30, 30)],
      );
      final String firstId = harness.state.strokes.first.id;

      final bool undone = harness.state.undoLastStroke();
      await tester.pump();

      expect(undone, isTrue);
      expect(harness.state.strokes, hasLength(1));
      expect(harness.state.strokes.single.id, firstId);
      expect(harness.reports.last, hasLength(1));
    });

    testWidgets('undoLastStroke on an empty canvas is a no-op', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      expect(harness.state.undoLastStroke(), isFalse);
      await tester.pump();
      expect(harness.state.strokes, isEmpty);
      expect(harness.reports, isEmpty);
    });

    testWidgets('clearStrokes empties the canvas and reports', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      harness.state.clearStrokes();
      await tester.pump();

      expect(harness.state.strokes, isEmpty);
      expect(harness.reports.last, isEmpty);
    });

    testWidgets('initial strokes are adopted and drawn on top of', (tester) async {
      final _CanvasHarness harness = _CanvasHarness(
        initialStrokes: const <InkStroke>[
          InkStroke(
            id: 'seed',
            width: 4,
            points: <InkPoint>[InkPoint(x: 1, y: 1), InkPoint(x: 9, y: 9)],
          ),
        ],
      );
      await harness.pump(tester);

      expect(harness.state.strokes, hasLength(1));
      expect(harness.state.strokes.single.id, 'seed');

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(50, 50), const Offset(80, 50)],
      );

      expect(harness.state.strokes, hasLength(2));
      expect(harness.state.strokes.first.id, 'seed');
      expect(harness.reports.single, hasLength(2));
    });

    testWidgets('strokes getter is an unmodifiable view', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);
      expect(
        () => harness.state.strokes.add(
          const InkStroke(id: 'x', width: 1, points: <InkPoint>[]),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('NotebookInkPainter', () {
    test('uses a round pen: round caps and round joins', () {
      const NotebookInkPainter painter = NotebookInkPainter(
        strokes: <InkStroke>[],
        activeStroke: null,
        revision: 0,
      );
      final Paint paint = painter.buildStrokePaint(5);
      expect(paint.strokeCap, StrokeCap.round);
      expect(paint.strokeJoin, StrokeJoin.round);
      expect(paint.style, PaintingStyle.stroke);
      expect(paint.strokeWidth, 5.0);
      expect(paint.color, NotebookInkCanvas.inkColor);
    });

    test('shouldRepaint is false for identical content, true on revision bump',
        () {
      const List<InkStroke> strokes = <InkStroke>[];
      const NotebookInkPainter a = NotebookInkPainter(
        strokes: strokes,
        activeStroke: null,
        revision: 3,
      );
      const NotebookInkPainter same = NotebookInkPainter(
        strokes: strokes,
        activeStroke: null,
        revision: 3,
      );
      const NotebookInkPainter bumped = NotebookInkPainter(
        strokes: strokes,
        activeStroke: null,
        revision: 4,
      );

      expect(a.shouldRepaint(same), isFalse);
      expect(a.shouldRepaint(bumped), isTrue);
    });

    test('paints single-point strokes as a dot without throwing', () {
      const NotebookInkPainter painter = NotebookInkPainter(
        strokes: <InkStroke>[
          InkStroke(
            id: 'dot',
            width: 8,
            points: <InkPoint>[InkPoint(x: 10, y: 10)],
          ),
          InkStroke(
            id: 'line',
            width: 2,
            points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 20, y: 20)],
          ),
        ],
        activeStroke: null,
        revision: 1,
      );

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      painter.paint(canvas, const Size(100, 100));
      expect(recorder.endRecording(), isNotNull);
    });
  });

  group('PenSizeControl', () {
    Future<void> pumpControl(
      WidgetTester tester, {
      double value = PenSizeControl.defaultPenWidth,
      required void Function(double) onChanged,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: PenSizeControl(value: value, onChanged: onChanged),
            ),
          ),
        ),
      );
    }

    testWidgets('exposes a 1.0 - 24.0 slider seeded at the current value',
        (tester) async {
      await pumpControl(tester, value: 9, onChanged: (_) {});

      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, PenSizeControl.minPenWidth);
      expect(slider.max, PenSizeControl.maxPenWidth);
      expect(PenSizeControl.minPenWidth, 1.0);
      expect(PenSizeControl.maxPenWidth, 24.0);
      expect(PenSizeControl.defaultPenWidth, 3.0);
      expect(slider.value, 9.0);
    });

    testWidgets('preview dot diameter tracks the current pen width',
        (tester) async {
      await pumpControl(tester, value: 12, onChanged: (_) {});
      expect(
        tester.getSize(find.byKey(PenSizeControl.previewDotKey)),
        const Size(12, 12),
      );

      await pumpControl(tester, value: 4, onChanged: (_) {});
      expect(
        tester.getSize(find.byKey(PenSizeControl.previewDotKey)),
        const Size(4, 4),
      );
    });

    testWidgets('reports slider changes to onChanged', (tester) async {
      final List<double> changes = <double>[];
      await pumpControl(tester, value: 3, onChanged: changes.add);

      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last, greaterThan(3.0));
      expect(changes.last, lessThanOrEqualTo(PenSizeControl.maxPenWidth));
      expect(
        changes.every((double v) => v >= PenSizeControl.minPenWidth),
        isTrue,
      );
    });

    testWidgets('is purely presentational: no internal state mutation',
        (tester) async {
      final List<double> changes = <double>[];
      await pumpControl(tester, value: 3, onChanged: changes.add);

      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pump();

      // Parent did not rebuild with a new value, so the slider stays put.
      expect(tester.widget<Slider>(find.byType(Slider)).value, 3.0);
      expect(find.byType(PenSizeControl), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

/// Records the ink [NotebookInkPainter] actually draws, in draw order.
///
/// Test-local on purpose: the painter carries no hooks of its own, so the
/// only way to observe real draw order is to watch the Canvas it is handed.
/// Strokes and fills are recorded into separate lists because they answer
/// different questions — `drawPath` in [PaintingStyle.stroke] is every
/// multi-point ballpoint stroke, every highlighter band and every selection
/// halo, while the fills are the fountain ribbon and the single-tap dot,
/// where the fill IS the whole visible mark.
class _RecordingCanvas implements Canvas {
  /// Stroked `drawPath` calls: ballpoint/highlighter strokes, the selection
  /// halo and the lasso marquee, in draw order.
  final List<Color> strokeColors = <Color>[];
  final List<double> strokeWidths = <double>[];

  /// Filled `drawPath` calls — the fountain ribbon.
  final List<_RecordedFill> fills = <_RecordedFill>[];

  /// `drawCircle` calls — single-point dots and a single-point halo.
  final List<_RecordedCircle> circles = <_RecordedCircle>[];

  @override
  void drawPath(Path path, Paint paint) {
    if (paint.style == PaintingStyle.fill) {
      fills.add(_RecordedFill(paint.color));
      return;
    }
    strokeColors.add(paint.color);
    strokeWidths.add(paint.strokeWidth);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add(_RecordedCircle(c, radius, paint.color, paint.style));

  /// Anything that draws and is not recorded above is a hole in these tests:
  /// the painter would be putting ink on the page that every assertion here
  /// is blind to. Fail loudly instead, per the sister recorder in
  /// `test/unit/models/notebook_fountain_painter_test.dart`. Non-`draw`
  /// members (save/restore/transform/clip) carry no ink and stay permissive.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    // `Symbol("drawOval")` — dart:mirrors is unavailable in a Flutter test,
    // so the name is read back off the Symbol's own toString.
    final String member =
        RegExp(r'"(.*)"').firstMatch('${invocation.memberName}')?.group(1) ??
            '';
    if (member.startsWith('draw')) {
      throw UnimplementedError('unrecorded canvas draw call: $member');
    }
    return null;
  }
}

/// A filled `drawPath` the painter made.
class _RecordedFill {
  const _RecordedFill(this.colour);
  final Color colour;
}

/// A `drawCircle` the painter made. [radius] is what proves a highlighter
/// tap is a band rather than a nib-sized dot.
class _RecordedCircle {
  const _RecordedCircle(this.centre, this.radius, this.colour, this.paintStyle);
  final Offset centre;
  final double radius;
  final Color colour;
  final PaintingStyle paintStyle;
}

/// `Paint.color` round-trips through float channels, so an identical colour
/// still fails `==`. Match on the channels instead.
Matcher _isColour(InkColor colour) {
  final Color expected = Color(colour.argb);
  return isA<Color>()
      .having((Color c) => c.r, 'r', closeTo(expected.r, 0.001))
      .having((Color c) => c.g, 'g', closeTo(expected.g, 0.001))
      .having((Color c) => c.b, 'b', closeTo(expected.b, 0.001))
      .having((Color c) => c.a, 'a', closeTo(expected.a, 0.001));
}

/// Test harness that owns the mutable inputs of [NotebookInkCanvas] so a test
/// can flip `penWidth` / `drawingEnabled` mid-session and rebuild.
class _CanvasHarness {
  _CanvasHarness({
    this.drawingEnabled = true,
    this.penWidth = 3,
    this.tool = InkTool.pen,
    this.colour = InkColor.white,
    List<InkStroke>? initialStrokes,
  })  : strokes = initialStrokes ?? const <InkStroke>[],
        // A tool holding another tool's ink is not a state a real toolbar
        // can reach, and InkStroke asserts on it. Catch a mis-staged test
        // here, where the message names the harness, instead of inside the
        // model where it reads as a production bug. Sourced from the model's
        // own palette so a future swatch cannot drift this copy.
        assert(
          InkColor.paletteFor(tool).contains(colour),
          'colour must belong to tool\'s palette (InkColor.paletteFor)',
        );

  final GlobalKey<NotebookInkCanvasState> canvasKey =
      GlobalKey<NotebookInkCanvasState>();
  final List<List<InkStroke>> reports = <List<InkStroke>>[];

  bool drawingEnabled;
  bool erasing = false;
  double penWidth;

  /// The toolbar selection. Always a legal pairing — see [setInstrument].
  InkTool tool;
  InkColor colour;
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
                    erasing: erasing,
                    penWidth: penWidth,
                    tool: tool,
                    colour: colour,
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

  Future<void> setErasing(WidgetTester tester, bool value) async {
    erasing = value;
    _setState(() {});
    await tester.pump();
  }

  /// Moves the toolbar selection. Tool and colour move together because the
  /// palette is tool-scoped: `InkColor.paletteFor(tool)` is the only legal
  /// source of a swatch, and an unnamed colour falls to that tool's default
  /// rather than carrying the old tool's ink across.
  Future<void> setInstrument(
    WidgetTester tester, {
    InkTool? tool,
    InkColor? colour,
  }) async {
    final bool switchedTool = tool != null && tool != this.tool;
    if (tool != null) this.tool = tool;
    // A tool switch that names no colour adopts the new tool's default —
    // the same rule InkStroke.copyWith applies, so the harness can never
    // stage a pairing the model would reject.
    this.colour =
        colour ?? (switchedTool ? InkColor.defaultFor(this.tool) : this.colour);
    assert(
      InkColor.paletteFor(this.tool).contains(this.colour),
      'setInstrument staged an illegal pairing: ${this.tool} with '
      '${this.colour} — name a colour from InkColor.paletteFor(tool)',
    );
    _setState(() {});
    await tester.pump();
  }
}

Offset _at(WidgetTester tester, Offset local) =>
    tester.getTopLeft(find.byType(NotebookInkCanvas)) + local;

/// The ink painter currently mounted inside the canvas — the one with the
/// live in-progress stroke, found by its type rather than an invented key.
NotebookInkPainter _livePainter(WidgetTester tester) {
  final Iterable<CustomPaint> paints = tester.widgetList<CustomPaint>(
    find.descendant(
      of: find.byType(NotebookInkCanvas),
      matching: find.byType(CustomPaint),
    ),
  );
  return paints
      .map((CustomPaint p) => p.painter)
      .whereType<NotebookInkPainter>()
      .single;
}

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
    testWidgets('paints white ink on the darkest chassis tone', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      // Ink is white, never the lime signal colour: lime ink competes with the
      // transcript and tires the eye over a page of notes.
      expect(NotebookInkCanvas.inkColor, TangentColors.ink);
      expect(NotebookInkCanvas.inkColor, isNot(TangentColors.signal));
      expect(NotebookInkCanvas.backgroundColor, TangentColors.sunken);

      final ColoredBox background = tester.widget<ColoredBox>(
        find.byKey(NotebookInkCanvas.backgroundKey),
      );
      expect(background.color, TangentColors.sunken);

      // Two painters are mounted — the ink and the hover ring — so the
      // finder collects them all and the assertion names the INK painter
      // explicitly (exactly one, ever: the exporter depends on that).
      final Iterable<CustomPaint> paints = tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(NotebookInkCanvas),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(
        paints
            .map((CustomPaint p) => p.painter)
            .whereType<NotebookInkPainter>(),
        hasLength(1),
      );
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

    testWidgets('stylus DOES draw when drawingEnabled is false',
        (tester) async {
      // Premise replaced, not weakened. This test previously asserted that a
      // pen was ignored unless draw mode was on; that requirement is gone --
      // a pen now writes wherever it touches the page, and the draw-mode
      // button is the backup for writing with a finger. The finger half of
      // the old contract is asserted immediately below and is unchanged.
      final _CanvasHarness harness = _CanvasHarness(drawingEnabled: false);
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(10, 10), const Offset(60, 60)],
      );

      expect(
        harness.state.strokes,
        isNotEmpty,
        reason: 'a pen writes with no mode toggle first',
      );
      expect(harness.reports, isNotEmpty);
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

    testWidgets('a stroke is born with the canvas tool and colour',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness(
        tool: InkTool.highlighter,
        colour: InkColor.pink,
      );
      await harness.pump(tester);

      final TestGesture gesture =
          await tester.startGesture(_at(tester, const Offset(10, 10)));
      await gesture.moveTo(_at(tester, const Offset(60, 10)));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final InkStroke stroke = harness.state.strokes.single;
      expect(stroke.tool, InkTool.highlighter);
      expect(stroke.colour, InkColor.pink);
      // The committed stroke reaches the host too — the durable list, not
      // just the canvas's private state.
      expect(harness.reports.single.single.tool, InkTool.highlighter);
      expect(harness.reports.single.single.colour, InkColor.pink);
    });

    testWidgets('a stroke keeps the tool and colour active when it STARTED',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness(
        tool: InkTool.highlighter,
        colour: InkColor.lime,
      );
      await harness.pump(tester);

      final TestGesture gesture =
          await tester.startGesture(_at(tester, const Offset(10, 10)));
      await tester.pump();
      // The toolbar changes instrument mid-stroke: the ink already flowing
      // must not change under the finger.
      await harness.setInstrument(tester, tool: InkTool.pen);
      await gesture.moveTo(_at(tester, const Offset(60, 10)));
      await tester.pump();

      // The LIVE PREVIEW must hold the latch too — not just the committed
      // stroke. If the preview re-reads the widget selection, the ink
      // visibly recolours under the finger while drawing, then snaps back
      // on lift; the committed-stroke assertions below would stay green.
      final InkStroke active = _livePainter(tester).activeStroke!;
      expect(
        active.tool,
        InkTool.highlighter,
        reason: 'the in-progress ink keeps the tool it started with',
      );
      expect(
        active.colour,
        InkColor.lime,
        reason: 'the in-progress ink keeps the colour it started with',
      );

      await gesture.up();
      await tester.pump();

      final InkStroke stroke = harness.state.strokes.single;
      expect(
        stroke.tool,
        InkTool.highlighter,
        reason: 'the stroke keeps the tool it started with',
      );
      expect(
        stroke.colour,
        InkColor.lime,
        reason: 'the stroke keeps the ink it started with',
      );
    });

    testWidgets('the live preview stroke carries the selected tool and colour',
        (tester) async {
      // Deliberately a NON-default swatch: yellow is defaultFor(highlighter),
      // so a preview that collapsed colour to the tool default would pass
      // with yellow and this test would defend nothing.
      final _CanvasHarness harness = _CanvasHarness(
        tool: InkTool.highlighter,
        colour: InkColor.pink,
      );
      await harness.pump(tester);

      final TestGesture gesture =
          await tester.startGesture(_at(tester, const Offset(10, 10)));
      await gesture.moveTo(_at(tester, const Offset(60, 10)));
      await tester.pump();

      // Mid-stroke: the in-progress ink must already render as a highlighter
      // band, not turn into one only on lift.
      final NotebookInkPainter painter = _livePainter(tester);
      final InkStroke active = painter.activeStroke!;
      expect(active.tool, InkTool.highlighter);
      expect(active.colour, InkColor.pink);

      await gesture.up();
      await tester.pump();
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

    testWidgets('a redone action can be undone again (ping-pong)',
        (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      expect(harness.state.undoLastStroke(), isTrue);
      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));

      // The redo must have re-armed undo: walking back works again.
      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(
        harness.state.strokes,
        isEmpty,
        reason: 'undo after redo must step back over the redone action',
      );

      // The stroke fallback can fake the above; an erase sweep cannot.
      // Redo twice more lands on the redone ERASE state (empty), and undo
      // from there must bring the ink back — impossible without the redo
      // path re-arming the undo stack.
      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));
      await harness.setErasing(tester, true);
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(15, 5), const Offset(16, 5)],
      );
      await harness.setErasing(tester, false);
      expect(harness.state.strokes, isEmpty);
      expect(harness.state.undoLastStroke(), isTrue);
      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, isEmpty, reason: 'redone erase');
      expect(
        harness.state.undoLastStroke(),
        isTrue,
        reason: 'undoing a redone erase must be possible',
      );
      await tester.pump();
      expect(
        harness.state.strokes,
        hasLength(1),
        reason: 'the ink erased by the redone sweep must return',
      );
    });

    testWidgets('undo and redo walk multiple steps', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      for (final double y in const <double>[5, 30, 55]) {
        await _drawStroke(
          tester,
          path: <Offset>[Offset(5, y), Offset(30, y)],
        );
      }
      final List<String> ids =
          harness.state.strokes.map((InkStroke s) => s.id).toList();
      expect(ids, hasLength(3));

      // Walk all the way back...
      expect(harness.state.undoLastStroke(), isTrue);
      expect(harness.state.undoLastStroke(), isTrue);
      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, isEmpty);
      expect(harness.state.undoLastStroke(), isFalse);

      // ...and all the way forward again, in order.
      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(
        harness.state.strokes.map((InkStroke s) => s.id),
        <String>[ids[0]],
      );
      expect(harness.state.redo(), isTrue);
      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(harness.state.strokes.map((InkStroke s) => s.id), ids);
      expect(harness.state.redo(), isFalse);
    });

    testWidgets('history steps through strokes AND an erase sweep',
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
      // Erase the second stroke as one sweep.
      await harness.setErasing(tester, true);
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(15, 30), const Offset(16, 30)],
      );
      await harness.setErasing(tester, false);
      expect(harness.state.strokes, hasLength(1));

      // Undo 1: the sweep comes back. Undo 2: second stroke gone.
      // Undo 3: first stroke gone.
      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, hasLength(2));
      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));
      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, isEmpty);

      // Redo all three actions lands back on the post-erase state.
      expect(harness.state.redo(), isTrue);
      expect(harness.state.redo(), isTrue);
      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(
        harness.state.strokes,
        hasLength(1),
        reason: 'the redone erase sweep must leave one stroke, as it did',
      );
      expect(harness.state.redo(), isFalse);
    });

    testWidgets('redo restores what undo removed', (tester) async {
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
      final String lastId = harness.state.strokes.last.id;

      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));

      final bool redone = harness.state.redo();
      await tester.pump();
      expect(redone, isTrue);
      expect(harness.state.strokes, hasLength(2));
      expect(
        harness.state.strokes.last.id,
        lastId,
        reason: 'redo must bring back the exact undone stroke',
      );
      expect(harness.reports.last, hasLength(2));
    });

    testWidgets('redo without a prior undo is a no-op', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      expect(harness.state.redo(), isFalse);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));
    });

    testWidgets('drawing after undo forfeits the redo', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();

      // A new stroke rewrites history; redoing the old one now would
      // interleave two futures.
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 30), const Offset(30, 30)],
      );
      expect(harness.state.redo(), isFalse);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));
    });

    testWidgets('redo revives an undone erase sweep undo', (tester) async {
      final _CanvasHarness harness = _CanvasHarness();
      await harness.pump(tester);

      await _drawStroke(
        tester,
        path: <Offset>[const Offset(5, 5), const Offset(30, 5)],
      );
      // Erase it with a real gesture, undo the erase (stroke back), then
      // redo (erased again).
      await harness.setErasing(tester, true);
      await _drawStroke(
        tester,
        path: <Offset>[const Offset(15, 5), const Offset(16, 5)],
      );
      expect(harness.state.strokes, isEmpty);
      await harness.setErasing(tester, false);

      expect(harness.state.undoLastStroke(), isTrue);
      await tester.pump();
      expect(harness.state.strokes, hasLength(1));

      expect(harness.state.redo(), isTrue);
      await tester.pump();
      expect(
        harness.state.strokes,
        isEmpty,
        reason: 'redo must re-apply the undone erase sweep',
      );
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
      // The paint's every property comes from the stroke, so the stroke is
      // required — a default-pen stroke is what makes this the pen case.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 5,
        points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 5, y: 5)],
      );
      final Paint paint = painter.buildStrokePaint(5, stroke: pen);
      expect(paint.strokeCap, StrokeCap.round);
      expect(paint.strokeJoin, StrokeJoin.round);
      expect(paint.style, PaintingStyle.stroke);
      expect(paint.strokeWidth, 5.0);
      // Paint.color round-trips through float channels, so `==` fails even
      // for an identical colour. Compare channels instead.
      const Color expected = NotebookInkCanvas.inkColor;
      expect(paint.color.r, closeTo(expected.r, 0.001));
      expect(paint.color.g, closeTo(expected.g, 0.001));
      expect(paint.color.b, closeTo(expected.b, 0.001));
      expect(paint.color.a, closeTo(expected.a, 0.001));
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

  group('highlighter rendering', () {
    test('highlighter strokes paint before pen strokes', () {
      // Insertion order is pen-then-highlighter; paint order must be the
      // reverse, or the highlight would cover the handwriting.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 10, y: 10)],
      );
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 0, y: 5), InkPoint(x: 10, y: 5)],
      );

      final List<String> order = NotebookInkPainter.paintOrder(
        const <InkStroke>[pen, mark],
      ).map((InkStroke s) => s.id).toList();

      expect(order, <String>['mark', 'pen']);
    });

    test('insertion order is preserved within a pass', () {
      // A later highlight still covers an earlier one.
      const InkStroke first = InkStroke(
        id: 'first',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 0, y: 5)],
      );
      const InkStroke second = InkStroke(
        id: 'second',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 1, y: 5)],
      );

      expect(
        NotebookInkPainter.paintOrder(const <InkStroke>[first, second])
            .map((InkStroke s) => s.id),
        <String>['first', 'second'],
      );
    });

    test('the active stroke paints last within its own pass', () {
      // Drawing a highlight over existing ink must show the ink staying on
      // top live, not only after the pen lifts.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        points: <InkPoint>[InkPoint(x: 0, y: 0)],
      );
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 0, y: 5)],
      );
      const InkStroke active = InkStroke(
        id: 'active',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 2, y: 5)],
      );

      expect(
        NotebookInkPainter.paintOrder(
          const <InkStroke>[pen, mark],
          active: active,
        ).map((InkStroke s) => s.id),
        <String>['mark', 'active', 'pen'],
      );
    });

    test('a highlighter stroke paints wider than its nominal width', () {
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 0, y: 5), InkPoint(x: 10, y: 5)],
      );
      final Paint paint = const NotebookInkPainter(
        strokes: <InkStroke>[],
        activeStroke: null,
        revision: 1,
      ).buildStrokePaint(mark.width, stroke: mark);

      expect(paint.strokeWidth, 3 * kHighlighterWidthFactor);
      expect(paint.strokeCap, StrokeCap.square);
      expect(paint.strokeJoin, StrokeJoin.bevel);
      // Paint.color round-trips through float channels, so `==` fails even
      // for an identical colour (see 'uses a round pen' above). Compare
      // channels. Alpha matters most here: a highlighter must stay
      // translucent or it would blot the ink it is painted beneath.
      const Color expected = Color(0x38FFE14D);
      expect(paint.color.r, closeTo(expected.r, 0.001));
      expect(paint.color.g, closeTo(expected.g, 0.001));
      expect(paint.color.b, closeTo(expected.b, 0.001));
      expect(paint.color.a, closeTo(expected.a, 0.001));
      expect(paint.color.a, lessThan(1.0));
    });

    test('a pen stroke keeps round caps and its own width', () {
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        colour: InkColor.red,
        points: <InkPoint>[InkPoint(x: 0, y: 0)],
      );
      final Paint paint = const NotebookInkPainter(
        strokes: <InkStroke>[],
        activeStroke: null,
        revision: 1,
      ).buildStrokePaint(pen.width, stroke: pen);

      expect(paint.strokeWidth, 3);
      expect(paint.strokeCap, StrokeCap.round);
      // Channel comparison, as above.
      const Color expected = Color(0xFFFF6B6B);
      expect(paint.color.r, closeTo(expected.r, 0.001));
      expect(paint.color.g, closeTo(expected.g, 0.001));
      expect(paint.color.b, closeTo(expected.b, 0.001));
      // Pen ink is fully opaque: that is what makes painting highlighters
      // beneath it safe.
      expect(paint.color.a, closeTo(1.0, 0.001));
    });

    test('a highlighter ignores the fountain nib', () {
      // A felt tip does not taper, whatever nib the toolbar has selected.
      // Proven through the paint it builds: a fountain stroke's width comes
      // from pressure, a highlighter's never does.
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        style: PenStyle.fountain,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[
          InkPoint(x: 0, y: 5, p: 0.1),
          InkPoint(x: 10, y: 5, p: 0.9),
        ],
      );
      expect(NotebookInkPainter.usesFountainPath(mark), isFalse);

      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        style: PenStyle.fountain,
        points: <InkPoint>[
          InkPoint(x: 0, y: 5, p: 0.1),
          InkPoint(x: 10, y: 5, p: 0.9),
        ],
      );
      expect(NotebookInkPainter.usesFountainPath(pen), isTrue);
    });

    test('paint draws highlighters first, active stroke included', () {
      // The functions above are only worth anything if `paint` actually
      // routes through them. Recording the real draw calls is what stops
      // `paintOrder` from silently becoming dead code while the ordering
      // tests stay green.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        colour: InkColor.red,
        points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 10, y: 10)],
      );
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 0, y: 5), InkPoint(x: 10, y: 5)],
      );
      const InkStroke active = InkStroke(
        id: 'active',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.lime,
        points: <InkPoint>[InkPoint(x: 0, y: 8), InkPoint(x: 10, y: 8)],
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookInkPainter(
        strokes: <InkStroke>[pen, mark],
        activeStroke: active,
        revision: 1,
      ).paint(canvas, const Size(100, 100));

      // Both highlighters land before the pen, and the live stroke is in the
      // ordered run rather than tacked on at the end where it would cover
      // the handwriting it is being drawn across.
      expect(canvas.strokeColors, <Matcher>[
        _isColour(InkColor.yellow),
        _isColour(InkColor.lime),
        _isColour(InkColor.red),
      ]);
      // Every mark is painted beneath the ink AND is translucent, which is
      // the pair of properties that makes a highlight readable over text.
      expect(canvas.strokeColors.first.a, lessThan(1.0));
      expect(canvas.strokeColors.last.a, closeTo(1.0, 0.001));
      // The pen keeps its own width; the marks are full bands.
      expect(canvas.strokeWidths, <double>[12.0, 12.0, 3.0]);
    });

    test('a single-point highlighter dot draws in its own translucent ink',
        () {
      // The dot fill never goes through `buildStrokePaint`, so the paint
      // tests above say nothing about it. A tap is the whole mark here: if
      // the dot fill lost the stroke's colour it would render opaque white
      // and blot the page instead of tinting it.
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 10, y: 10)],
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookInkPainter(
        strokes: <InkStroke>[mark],
        activeStroke: null,
        revision: 1,
      ).paint(canvas, const Size(100, 100));

      expect(canvas.circles, hasLength(1));
      expect(canvas.circles.single.paintStyle, PaintingStyle.fill);
      expect(canvas.circles.single.colour, _isColour(InkColor.yellow));
      expect(
        canvas.circles.single.colour.a,
        lessThan(1.0),
        reason: 'an opaque dot would blot the ink a highlight sits beneath',
      );
    });

    test('a highlighter dot is a full band, a pen dot is nib-sized', () {
      // One tap with the marker must still read as a band. Without the
      // factor a highlighter tap would be indistinguishable from a pen dot
      // of the same slider width.
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 10, y: 10)],
      );
      const InkStroke dot = InkStroke(
        id: 'dot',
        width: 3,
        points: <InkPoint>[InkPoint(x: 20, y: 20)],
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookInkPainter(
        strokes: <InkStroke>[dot, mark],
        activeStroke: null,
        revision: 1,
      ).paint(canvas, const Size(100, 100));

      // Highlighter first (paintOrder), pen second — same nominal width, and
      // only the mark is scaled to the band.
      expect(
        canvas.circles.map((_RecordedCircle c) => c.radius).toList(),
        <double>[3 * kHighlighterWidthFactor / 2, 1.5],
      );
    });

    test('a fountain stroke fills its ribbon in its own ink', () {
      // The ribbon IS the entire visible mark of a fountain stroke, and it
      // is filled by the same dot paint — red, so a silent fall back to the
      // default white ink cannot pass by accident.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 4,
        style: PenStyle.fountain,
        colour: InkColor.red,
        points: <InkPoint>[
          InkPoint(x: 0, y: 0, p: 0.2),
          InkPoint(x: 10, y: 0, p: 0.8),
          InkPoint(x: 20, y: 0, p: 0.5),
        ],
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookInkPainter(
        strokes: <InkStroke>[pen],
        activeStroke: null,
        revision: 1,
      ).paint(canvas, const Size(100, 100));

      expect(
        canvas.strokeColors,
        isEmpty,
        reason: 'the italic nib fills a ribbon, it never strokes a line',
      );
      expect(canvas.fills, hasLength(1));
      expect(canvas.fills.single.colour, _isColour(InkColor.red));
      expect(canvas.fills.single.colour.a, closeTo(1.0, 0.001));
    });

    test('a selected highlighter haloes around its full band', () {
      // The glow has to track the band, not the nominal width, or a selected
      // mark would show its halo buried inside itself.
      const InkStroke pen = InkStroke(
        id: 'pen',
        width: 3,
        points: <InkPoint>[InkPoint(x: 0, y: 0), InkPoint(x: 10, y: 10)],
      );
      const InkStroke mark = InkStroke(
        id: 'mark',
        width: 3,
        tool: InkTool.highlighter,
        colour: InkColor.yellow,
        points: <InkPoint>[InkPoint(x: 0, y: 5), InkPoint(x: 10, y: 5)],
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookInkPainter(
        strokes: <InkStroke>[pen, mark],
        activeStroke: null,
        revision: 1,
        selectedIds: <String>{'pen', 'mark'},
      ).paint(canvas, const Size(100, 100));

      // Halo then ink, per stroke, in paint order: the mark's halo clears
      // its 12-wide band while the pen — identical nominal width — gets a
      // halo around 3.
      expect(canvas.strokeWidths, <double>[
        3 * kHighlighterWidthFactor + 8,
        3 * kHighlighterWidthFactor,
        3 + 8,
        3,
      ]);
    });
  });

  group('_RecordingCanvas', () {
    test('throws on a draw call it does not record', () {
      // Hardening, not behaviour: if the painter ever draws ink through a
      // method this fixture ignores, every order and colour test above would
      // silently observe less than was drawn. Fail loudly instead.
      final _RecordingCanvas canvas = _RecordingCanvas();
      expect(
        () => canvas.drawLine(Offset.zero, const Offset(1, 1), Paint()),
        throwsUnimplementedError,
      );
      expect(
        () => canvas.drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()),
        throwsUnimplementedError,
      );
      // Structural calls carry no ink and stay permissive.
      expect(
        () {
          canvas.save();
          canvas.translate(1, 1);
          canvas.restore();
        },
        returnsNormally,
      );
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

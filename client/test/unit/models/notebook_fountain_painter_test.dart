// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fountain renderer, proven at the paint level.
//
// A widget test can prove a stroke was captured; only driving the painter
// directly proves what was DRAWN — that pressure actually varies the width,
// that legacy flat strokes still render as one path, and that the taper
// floor keeps a zero-pressure segment visible.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

/// Records every line and path drawn; throws on anything else.
class _RecordingCanvas implements Canvas {
  final List<double> lineWidths = <double>[];
  final List<Rect> pathBounds = <Rect>[];
  int paths = 0;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lineWidths.add(paint.strokeWidth);

  @override
  void drawPath(Path path, Paint paint) {
    paths++;
    pathBounds.add(path.getBounds());
    drawnPaths.add(path);
  }

  final List<Path> drawnPaths = <Path>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected canvas call');
}

void main() {
  NotebookInkPainter painterFor(InkStroke stroke) => NotebookInkPainter(
        strokes: <InkStroke>[stroke],
        activeStroke: null,
        revision: 0,
      );

  // For the HORIZONTAL strokes used here, an italic quad's bounding-box
  // height is nibWidth * sin(30°), so the drawn nib width is height * 2.
  double nibWidthOf(Rect bounds) => bounds.height * 2;

  test('a fountain stroke draws quads whose width follows pressure', () {
    final _RecordingCanvas canvas = _RecordingCanvas();
    painterFor(
      const InkStroke(
        id: 's',
        width: 4,
        style: PenStyle.fountain,
        points: <InkPoint>[
          InkPoint(x: 0, y: 0, p: 0.1),
          InkPoint(x: 10, y: 0, p: 0.5),
          InkPoint(x: 20, y: 0, p: 1.0),
        ],
      ),
    ).paint(canvas, const Size(100, 100));

    expect(canvas.paths, 2, reason: 'one italic quad per segment');
    expect(
      canvas.lineWidths,
      isEmpty,
      reason: 'the italic nib never strokes lines',
    );
    expect(
      nibWidthOf(canvas.pathBounds[1]),
      greaterThan(nibWidthOf(canvas.pathBounds[0])),
      reason: 'harder pressure must draw wider',
    );
  });

  test('normal writing pressure reaches the pen nominal width', () {
    // Hardware-tuned: the linear curve made Jeff press about twice as hard
    // as natural writing. A quarter of the sensor range is a normal hand,
    // and it must already earn the full chosen width.
    final _RecordingCanvas canvas = _RecordingCanvas();
    painterFor(
      const InkStroke(
        id: 's',
        width: 4,
        style: PenStyle.fountain,
        points: <InkPoint>[
          InkPoint(x: 0, y: 0, p: 0.25),
          InkPoint(x: 10, y: 0, p: 0.25),
        ],
      ),
    ).paint(canvas, const Size(100, 100));

    expect(
      nibWidthOf(canvas.pathBounds.single),
      greaterThanOrEqualTo(4),
      reason: 'a normal hand must not have to lean on the pen',
    );
  });

  test('zero pressure still leaves visible ink', () {
    final _RecordingCanvas canvas = _RecordingCanvas();
    painterFor(
      const InkStroke(
        id: 's',
        width: 4,
        style: PenStyle.fountain,
        points: <InkPoint>[
          InkPoint(x: 0, y: 0, p: 0),
          InkPoint(x: 10, y: 0, p: 0),
        ],
      ),
    ).paint(canvas, const Size(100, 100));

    expect(
      nibWidthOf(canvas.pathBounds.single),
      greaterThan(0),
      reason: 'a light-handed stroke must not vanish',
    );
  });

  test('a ballpoint stroke still renders as one flat path', () {
    final _RecordingCanvas canvas = _RecordingCanvas();
    painterFor(
      const InkStroke(
        id: 's',
        width: 4,
        points: <InkPoint>[
          InkPoint(x: 0, y: 0),
          InkPoint(x: 10, y: 0),
          InkPoint(x: 20, y: 10),
        ],
      ),
    ).paint(canvas, const Size(100, 100));

    expect(canvas.paths, 1);
    expect(
      canvas.lineWidths,
      isEmpty,
      reason: 'the legacy renderer is untouched',
    );
  });

  test('a fountain stroke from a legacy file (no pressure) renders flat', () {
    final _RecordingCanvas canvas = _RecordingCanvas();
    painterFor(
      const InkStroke(
        id: 's',
        width: 4,
        style: PenStyle.fountain,
        points: <InkPoint>[
          InkPoint(x: 0, y: 0),
          InkPoint(x: 10, y: 0),
        ],
      ),
    ).paint(canvas, const Size(100, 100));

    expect(
      nibWidthOf(canvas.pathBounds.single),
      closeTo(4, 0.001),
      reason: 'no pressure data degrades to the flat width',
    );
  });

  test('stroke direction changes the italic width', () {
    // The chisel edge: a stroke ALONG the 30-degree nib direction lays the
    // edge down its own path and nearly vanishes; across it, full width.
    // Bounding boxes cannot see this (a thin diagonal still has a fat box),
    // so the quads are probed directly: a point 1px to the side of the
    // stroke's midline is ink only when the nib is presented across the
    // stroke.
    final _RecordingCanvas canvas = _RecordingCanvas();
    const double c = 0.8660254037844387; // cos 30°
    painterFor(
      const InkStroke(
        id: 's',
        width: 4,
        style: PenStyle.fountain,
        points: <InkPoint>[
          // Segment 1: along the nib edge (30° up to the right).
          InkPoint(x: 0, y: 20, p: 0.5),
          InkPoint(x: 10 * c, y: 20 - 5, p: 0.5),
          // Segment 2: perpendicular to the nib edge.
          InkPoint(x: 10 * c + 5, y: 20 - 5 + 10 * c, p: 0.5),
        ],
      ),
    ).paint(canvas, const Size(100, 100));

    expect(canvas.paths, 2);
    // Midpoint of each segment, probed 1px perpendicular to the segment.
    const Offset alongProbe =
        Offset(10 * c / 2 + 0.5, 17.5 + c); // perp of (c, -0.5) is (0.5, c)
    const Offset acrossProbe =
        Offset(10 * c + 2.5 + c, 15 + 5 * c - 0.5); // perp of (0.5, c)
    expect(
      canvas.drawnPaths[1].contains(acrossProbe),
      isTrue,
      reason: 'across the nib the stroke is full-bodied',
    );
    expect(
      canvas.drawnPaths[0].contains(alongProbe),
      isFalse,
      reason: 'along the nib the stroke thins to nearly nothing',
    );
  });
}

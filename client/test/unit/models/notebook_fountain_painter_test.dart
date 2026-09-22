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

    expect(
      canvas.paths,
      1,
      reason: 'the whole stroke batches into ONE path — a path per segment '
          'made full-page repaints O(total segments) in native draw calls, '
          'which dragged the eraser once a page filled up',
    );
    expect(
      canvas.lineWidths,
      isEmpty,
      reason: 'the italic nib never strokes lines',
    );
    // Width still follows pressure inside the batched path. For these
    // horizontal segments a quad reaches width*sin(30°)/2 = width/4 above
    // the midline: the light segment (avg p=0.3, ~4.49 wide, half ~1.12)
    // must NOT reach y=1.3, the heavy one (avg p=0.75, ~5.86 wide,
    // half ~1.46) must.
    final Path ribbon = canvas.drawnPaths.single;
    expect(
      ribbon.contains(const Offset(5, 1.3)),
      isFalse,
      reason: 'light pressure stays narrow',
    );
    expect(
      ribbon.contains(const Offset(15, 1.3)),
      isTrue,
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

    expect(canvas.paths, 1, reason: 'both segments batch into one path');
    // Midpoint of each segment, probed 1px perpendicular to the segment.
    // The probes work unchanged against the batched path: the along-the-nib
    // probe sits outside BOTH segments' quads, the across probe inside its
    // own.
    const Offset alongProbe =
        Offset(10 * c / 2 + 0.5, 17.5 + c); // perp of (c, -0.5) is (0.5, c)
    const Offset acrossProbe =
        Offset(10 * c + 2.5 + c, 15 + 5 * c - 0.5); // perp of (0.5, c)
    final Path ribbon = canvas.drawnPaths.single;
    expect(
      ribbon.contains(acrossProbe),
      isTrue,
      reason: 'across the nib the stroke is full-bodied',
    );
    expect(
      ribbon.contains(alongProbe),
      isFalse,
      reason: 'along the nib the stroke thins to nearly nothing',
    );
  });

  group('winding normalization - no holes where a stroke crosses itself', () {
    // The regression behind the "erased ink" holes on real pages: 8fd6e60
    // batched every quad into ONE nonZero path, but each quad's winding
    // orientation is sign(cross(b-a, nibEdge)). Cursive loops and
    // reversals flip that sign, and wherever two opposite-winding quads
    // OVERLAP (letter crossings) nonZero summed +1-1=0 — a transparent
    // hole punched exactly where ink crossed ink. The fix emits every
    // quad with one consistent orientation, so overlaps sum to >=1.

    // The renderer's nib edge, replicated so each test PROVES its points
    // actually produce a winding flip rather than assuming it.
    const Offset nibEdge = Offset(0.8660254037844387, -0.5); // 30°, y-down
    double crossWithNib(Offset d) => d.dx * nibEdge.dy - d.dy * nibEdge.dx;

    test('a self-crossing loop keeps ink at the crossing', () {
      // A cursive-loop skeleton: right along a baseline, curl below it,
      // then straight back UP through it. The up-stroke crosses the
      // baseline segment at exactly (20, 10).
      const Offset p0 = Offset(0, 10);
      const Offset p1 = Offset(30, 10); // baseline, rightward
      const Offset p2 = Offset(20, 22); // connector, below the line
      const Offset p3 = Offset(20, -5); // straight up, crossing p0->p1

      // Prove the construction: the two OVERLAPPING segments wind
      // opposite ways under the original vertex order.
      expect(crossWithNib(p1 - p0), lessThan(0));
      expect(
        crossWithNib(p3 - p2),
        greaterThan(0),
        reason: 'the up-stroke must wind opposite to the baseline, or '
            'this test does not reproduce the cancellation at all',
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      painterFor(
        const InkStroke(
          id: 's',
          width: 4,
          style: PenStyle.fountain,
          points: <InkPoint>[
            InkPoint(x: 0, y: 10, p: 0.5),
            InkPoint(x: 30, y: 10, p: 0.5),
            InkPoint(x: 20, y: 22, p: 0.5),
            InkPoint(x: 20, y: -5, p: 0.5),
          ],
        ),
      ).paint(canvas, const Size(100, 100));

      expect(
        canvas.paths,
        1,
        reason: 'the fix must not give up the one-path perf contract',
      );
      // (20, 10) is the crossing point itself: dead centre of BOTH quads
      // (u = 0 in each parametrisation a + t*(b-a) + u*half, with
      // t = 2/3 and t = 12/27) and provably outside the connector quad
      // (its t solves to about -0.93). Before the winding fix nonZero
      // summed +1-1=0 here, so the ink had a hole at its own crossing.
      expect(
        canvas.drawnPaths.single.contains(const Offset(20, 10)),
        isTrue,
        reason: 'ink over ink must stay ink — the crossing had a hole',
      );
    });

    test('a direction reversal (retraced line) keeps its ink', () {
      // Straight out and straight back: the retrace quad is the SAME
      // parallelogram wound the other way, so before the fix the whole
      // stroke cancelled itself to zero painted area.
      expect(
        crossWithNib(const Offset(20, 0)) * crossWithNib(const Offset(-20, 0)),
        lessThan(0),
        reason: 'a reversal flips the winding sign',
      );

      final _RecordingCanvas canvas = _RecordingCanvas();
      painterFor(
        const InkStroke(
          id: 's',
          width: 4,
          style: PenStyle.fountain,
          points: <InkPoint>[
            InkPoint(x: 0, y: 0, p: 0.5),
            InkPoint(x: 20, y: 0, p: 0.5),
            InkPoint(x: 0, y: 0, p: 0.5),
          ],
        ),
      ).paint(canvas, const Size(100, 100));

      expect(canvas.paths, 1, reason: 'still one batched path');
      // (10, 0) is the exact centre of both overlapping quads.
      expect(
        canvas.drawnPaths.single.contains(const Offset(10, 0)),
        isTrue,
        reason: 'a retraced stroke must not erase itself',
      );
    });
  });
}

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
  int paths = 0;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lineWidths.add(paint.strokeWidth);

  @override
  void drawPath(Path path, Paint paint) => paths++;

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

  test('a fountain stroke draws segments whose width follows pressure', () {
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

    expect(canvas.lineWidths, hasLength(2));
    expect(canvas.paths, 0, reason: 'fountain renders as segments, not a path');
    expect(
      canvas.lineWidths[1],
      greaterThan(canvas.lineWidths[0]),
      reason: 'harder pressure must draw wider',
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
      canvas.lineWidths.single,
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
      canvas.lineWidths.single,
      4,
      reason: 'no pressure data degrades to the flat width',
    );
  });
}

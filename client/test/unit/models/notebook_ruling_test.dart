// SPDX-License-Identifier: AGPL-3.0-or-later
/// Page ruling: the stored value, the spacing, and the palette contract.
///
/// Spacing is a physical measurement, not a taste call, so it is pinned here:
/// changing a preset should require changing this file deliberately.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook_ruling.dart';
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/notebook_ink_canvas.dart';

/// Counts the lines a painter draws onto a canvas of [height].
int _linesDrawn(NotebookRuling ruling, {double height = 1000}) {
  final _RecordingCanvas canvas = _RecordingCanvas();
  NotebookRulingPainter(ruling: ruling)
      .paint(canvas, Size(800, height));
  return canvas.lines.length;
}

void main() {
  group('stored value', () {
    test('every ruling round-trips through its wire value', () {
      for (final NotebookRuling ruling in NotebookRuling.values) {
        expect(NotebookRuling.parse(ruling.wireValue), ruling);
      }
    });

    test('an absent or unknown value reads as blank', () {
      // Null is an existing notebook from before this column existed. An
      // unknown string is a ruling written by a newer build; rendering it as
      // blank is honest and leaves the stored value intact.
      expect(NotebookRuling.parse(null), NotebookRuling.blank);
      expect(NotebookRuling.parse(''), NotebookRuling.blank);
      expect(NotebookRuling.parse('dotted-grid'), NotebookRuling.blank);
    });

    test('wire values are names, not indices', () {
      // An index would silently re-rule every notebook if this enum were ever
      // reordered.
      expect(NotebookRuling.small.wireValue, 'small');
      expect(NotebookRuling.medium.wireValue, 'medium');
      expect(NotebookRuling.graph.wireValue, 'graph');
      expect(NotebookRuling.dots.wireValue, 'dots');
    });

    test('graph and dots parse back explicitly', () {
      // The values loop above already proves this, but these two are the new
      // wire words this arc ships; name them.
      expect(NotebookRuling.parse('graph'), NotebookRuling.graph);
      expect(NotebookRuling.parse('dots'), NotebookRuling.dots);
    });
  });

  group('spacing', () {
    test('presets match the ruled-paper standards they claim', () {
      // 280 dpi / 160 = 1.75, so 1 mm = 6.3 logical px.
      // narrow ruled  6.35 mm -> 40 px; college ruled 7.1 mm -> 45 px.
      expect(NotebookRuling.small.lineSpacing, 40);
      expect(NotebookRuling.medium.lineSpacing, 45);
    });

    test('graph and dots share the 5 mm quad-rule spacing', () {
      // 5 mm at 6.3 px/mm rounds to 32 logical px.
      expect(NotebookRuling.graph.lineSpacing, 32);
      expect(NotebookRuling.dots.lineSpacing, 32);
    });

    test('small is tighter than medium', () {
      expect(
        NotebookRuling.small.lineSpacing,
        lessThan(NotebookRuling.medium.lineSpacing),
      );
    });

    test('blank has no spacing at all', () {
      // Zero is what makes "is this ruled?" one question instead of two flags
      // that can disagree.
      expect(NotebookRuling.blank.lineSpacing, 0);
    });
  });

  group('painting', () {
    test('a blank page draws nothing', () {
      expect(_linesDrawn(NotebookRuling.blank), 0);
    });

    test('a ruled page draws a line per gap', () {
      // 1000 / 40 = 25 gaps, minus the one at y=1000 which is off the page.
      expect(_linesDrawn(NotebookRuling.small, height: 1000), 24);
      expect(_linesDrawn(NotebookRuling.medium, height: 1000), 22);
    });

    test('small and medium keep their exact line positions', () {
      // Byte-identical to the pre-graph painter: restructuring paint onto a
      // switch must not move a single line under existing notebooks.
      final _RecordingCanvas small = _RecordingCanvas();
      const NotebookRulingPainter(ruling: NotebookRuling.small)
          .paint(small, const Size(800, 200));
      expect(small.lines, <(Offset, Offset)>[
        (const Offset(0, 40), const Offset(800, 40)),
        (const Offset(0, 80), const Offset(800, 80)),
        (const Offset(0, 120), const Offset(800, 120)),
        (const Offset(0, 160), const Offset(800, 160)),
      ]);
      expect(small.circles, isEmpty, reason: 'lined pages draw only lines');

      final _RecordingCanvas medium = _RecordingCanvas();
      const NotebookRulingPainter(ruling: NotebookRuling.medium)
          .paint(medium, const Size(800, 200));
      expect(medium.lines, <(Offset, Offset)>[
        (const Offset(0, 45), const Offset(800, 45)),
        (const Offset(0, 90), const Offset(800, 90)),
        (const Offset(0, 135), const Offset(800, 135)),
        (const Offset(0, 180), const Offset(800, 180)),
      ]);
      expect(medium.circles, isEmpty);
    });

    test('graph draws verticals AND horizontals at the grid spacing', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookRulingPainter(ruling: NotebookRuling.graph)
          .paint(canvas, const Size(100, 80));
      expect(
        canvas.lines,
        containsAll(<(Offset, Offset)>[
          // Horizontals every 32 px, one gap down from the top.
          (const Offset(0, 32), const Offset(100, 32)),
          (const Offset(0, 64), const Offset(100, 64)),
          // Verticals every 32 px — a graph with no verticals is just a
          // lined page wearing the wrong label.
          (const Offset(32, 0), const Offset(32, 80)),
          (const Offset(64, 0), const Offset(64, 80)),
          (const Offset(96, 0), const Offset(96, 80)),
        ]),
      );
      expect(canvas.lines, hasLength(5), reason: 'nothing beyond the grid');
      expect(canvas.circles, isEmpty, reason: 'graph is lines, not dots');
    });

    test('dots draws circles at the intersections and no lines at all', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      const NotebookRulingPainter(ruling: NotebookRuling.dots)
          .paint(canvas, const Size(100, 80));
      expect(canvas.lines, isEmpty, reason: 'a dot grid has no lines');
      // Radius tracks the constant rather than a literal: the POSITIONS are
      // what this test guards, and tuning dot weight for legibility should
      // not have to touch six magic numbers.
      const double r = NotebookRulingPainter.dotRadius;
      expect(canvas.circles, <(Offset, double)>[
        (const Offset(32, 32), r),
        (const Offset(64, 32), r),
        (const Offset(96, 32), r),
        (const Offset(32, 64), r),
        (const Offset(64, 64), r),
        (const Offset(96, 64), r),
      ]);
    });

    test('graph and dots paint the same low-contrast guide colour', () {
      for (final NotebookRuling ruling in <NotebookRuling>[
        NotebookRuling.graph,
        NotebookRuling.dots,
      ]) {
        final _RecordingCanvas canvas = _RecordingCanvas();
        NotebookRulingPainter(ruling: ruling)
            .paint(canvas, const Size(100, 80));
        expect(canvas.colors, isNotEmpty);
        // Compare ARGB values: Paint re-wraps its colour, so the object is
        // never identical to the const token even when the colour is.
        const Color want = NotebookRulingPainter.lineColor;
        for (final Color c in canvas.colors) {
          // Paint stores channels as float32, so compare to within half an
          // 8-bit step rather than exactly.
          expect(c.a, closeTo(want.a, 1 / 512));
          expect(c.r, closeTo(want.r, 1 / 512));
          expect(c.g, closeTo(want.g, 1 / 512));
          expect(c.b, closeTo(want.b, 1 / 512));
        }
      }
    });

    test('a tighter ruling draws more lines on the same page', () {
      expect(
        _linesDrawn(NotebookRuling.small),
        greaterThan(_linesDrawn(NotebookRuling.medium)),
      );
    });

    test('an infinite canvas paints nothing instead of hanging', () {
      // An unbounded parent hands a painter infinite width, which has crashed
      // this app before. A zero spacing would loop forever.
      expect(_linesDrawn(NotebookRuling.small, height: double.infinity), 0);
      expect(_linesDrawn(NotebookRuling.graph, height: double.infinity), 0);
      expect(_linesDrawn(NotebookRuling.dots, height: double.infinity), 0);
    });

    test('changing the ruling repaints; keeping it does not', () {
      const NotebookRulingPainter small =
          NotebookRulingPainter(ruling: NotebookRuling.small);
      expect(
        small.shouldRepaint(
          const NotebookRulingPainter(ruling: NotebookRuling.medium),
        ),
        isTrue,
      );
      expect(
        small.shouldRepaint(
          const NotebookRulingPainter(ruling: NotebookRuling.small),
        ),
        isFalse,
      );
    });
  });

  group('palette contract', () {
    test('rule lines are not the ink colour', () {
      // Ink stays white and must never have to compete with the ruling.
      expect(
        NotebookRulingPainter.lineColor,
        isNot(NotebookInkCanvas.inkColor),
      );
    });

    test('rule lines are not the signal colour', () {
      // Lime means "live or selected". A ruled page is neither.
      expect(NotebookRulingPainter.lineColor, isNot(TangentColors.signal));
      expect(NotebookRulingPainter.lineColor, isNot(TangentColors.record));
    });

    test('rule lines sit far below the ink in contrast', () {
      // The guide must be visible without reading as content. Ink should be
      // several times brighter against the page than the lines are.
      final double inkOnPage = _contrast(
        NotebookInkCanvas.inkColor,
        NotebookInkCanvas.backgroundColor,
      );
      final double lineOnPage = _contrast(
        NotebookRulingPainter.lineColor,
        NotebookInkCanvas.backgroundColor,
      );

      expect(
        lineOnPage,
        lessThan(inkOnPage / 4),
        reason: 'ruling must recede behind handwriting, not compete with it',
      );
      // Jeff's v1.22.0 device feedback: "the lines and dots are too dim".
      // The old floor was 1.05, which the then-current colour cleared at
      // 1.42:1 while being effectively invisible on a tablet at arm's
      // length — a floor nothing can fail is not a floor. 2.5:1 is the
      // lowest ratio that read as a usable guide on the S11 Ultra.
      expect(
        lineOnPage,
        greaterThan(2.5),
        reason: 'a line nobody can see is not a ruled page',
      );
    });
  });
}

double _channel(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Records lines and circles; anything else THROWS, so a painter that starts
/// drawing rects or paths cannot slip past these tests unnoticed.
class _RecordingCanvas implements Canvas {
  final List<(Offset, Offset)> lines = <(Offset, Offset)>[];
  final List<(Offset, double)> circles = <(Offset, double)>[];
  final List<Color> colors = <Color>[];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lines.add((p1, p2));
    colors.add(paint.color);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circles.add((c, radius));
    colors.add(paint.color);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected canvas call');
}

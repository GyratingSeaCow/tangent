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
  final _CountingCanvas canvas = _CountingCanvas();
  NotebookRulingPainter(ruling: ruling)
      .paint(canvas, Size(800, height));
  return canvas.lines;
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
    });
  });

  group('spacing', () {
    test('presets match the ruled-paper standards they claim', () {
      // 280 dpi / 160 = 1.75, so 1 mm = 6.3 logical px.
      // narrow ruled  6.35 mm -> 40 px; college ruled 7.1 mm -> 45 px.
      expect(NotebookRuling.small.lineSpacing, 40);
      expect(NotebookRuling.medium.lineSpacing, 45);
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
      expect(
        lineOnPage,
        greaterThan(1.05),
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

/// A canvas that only counts drawLine calls.
class _CountingCanvas implements Canvas {
  int lines = 0;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected canvas call');
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// Page ruling for notebooks.
///
/// Spacing is derived from real ruled-paper standards rather than picked by
/// eye, so the presets mean something physical: on the Tab S10 FE (280 dpi,
/// devicePixelRatio 1.75) one millimetre is 6.3 logical pixels.
///
///   narrow ruled  6.35 mm -> 40 logical px  ("small")
///   college ruled 7.1  mm -> 45 logical px  ("medium")
///   quad ruled    5    mm -> 32 logical px  ("graph", "dots")
///
/// The page is a fixed-scale vertical roll with no pinch/zoom, so a rule line
/// is a fixed device-pixel spacing and never a zoom-relative one.
library;

import 'package:flutter/material.dart';

import '../theme/tangent_tokens.dart';

/// How a notebook page is ruled.
enum NotebookRuling {
  /// No rule lines. The default, and what every notebook created before this
  /// feature existed must keep rendering as.
  blank,

  /// Narrow ruled, 6.35 mm.
  small,

  /// College ruled, 7.1 mm.
  medium,

  /// Quad ruled, 5 mm: vertical and horizontal lines forming squares.
  graph,

  /// Dot grid, 5 mm: a dot at each grid intersection, nothing between.
  dots;

  /// Round-trips through the database. Stored as text rather than an index so
  /// reordering this enum can never silently re-rule existing notebooks.
  String get wireValue => name;

  /// Parses a stored value, falling back to [blank].
  ///
  /// An unknown value means a newer version of the app wrote a ruling this
  /// build does not understand; rendering it as blank is the honest answer,
  /// and it leaves the stored value alone for the newer build to use again.
  static NotebookRuling parse(String? raw) {
    for (final NotebookRuling ruling in NotebookRuling.values) {
      if (ruling.wireValue == raw) return ruling;
    }
    return NotebookRuling.blank;
  }

  /// Gap between rule lines — or grid lines, or dots — in logical pixels.
  ///
  /// Zero for [blank], which is what makes "is this page ruled?" a single
  /// question rather than a second flag that can disagree with this one.
  double get lineSpacing => switch (this) {
        NotebookRuling.blank => 0,
        NotebookRuling.small => 40,
        NotebookRuling.medium => 45,
        NotebookRuling.graph => 32,
        NotebookRuling.dots => 32,
      };

  /// What the picker shows.
  String get label => switch (this) {
        NotebookRuling.blank => 'Blank',
        NotebookRuling.small => 'Lined (small)',
        NotebookRuling.medium => 'Lined (medium)',
        NotebookRuling.graph => 'Graph',
        NotebookRuling.dots => 'Dot grid',
      };
}

/// Paints rule lines beneath everything else on the page.
///
/// Lines are a low-contrast chassis tone: they must never compete with
/// handwriting (which stays white) nor read as the lime signal colour, which
/// means "live or selected" everywhere else in this app.
class NotebookRulingPainter extends CustomPainter {
  const NotebookRulingPainter({required this.ruling});

  final NotebookRuling ruling;

  /// Deliberately dim, but not invisible. On the near-black page (sunken,
  /// #0E1113) this reads as a guide rather than as content, and it is nowhere
  /// near the lime signal colour, which means "live or selected" everywhere
  /// else in this app. It is NOT `edge`: a hairline divider only separates
  /// panels, while ruling has to be followed by a hand holding a stylus —
  /// `edge` measured 1.42:1 on the page and vanished on a tablet at arm's
  /// length.
  static const Color lineColor = TangentColors.rule;

  /// Dot-grid dots: just visible at arm's length without ever reading as
  /// punctuation someone wrote. Slightly fatter than a rule line's 1 px
  /// stroke because a dot has far less area to be seen by — at r=1.5 with
  /// the old dim colour the grid was effectively invisible on the tablet.
  static const double dotRadius = 1.8;

  @override
  void paint(Canvas canvas, Size size) {
    final double spacing = ruling.lineSpacing;
    // A zero or non-finite spacing would loop forever. An unbounded parent
    // hands a painter infinite width, which has crashed this app before.
    if (spacing <= 0 || !size.height.isFinite || !size.width.isFinite) return;

    final Paint paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    switch (ruling) {
      case NotebookRuling.blank:
        return; // Unreachable: blank's zero spacing already returned above.
      case NotebookRuling.small:
      case NotebookRuling.medium:
        // Start one full gap down so the first line is not flush against the
        // top edge, where it would read as a border rather than as ruling.
        for (double y = spacing; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case NotebookRuling.graph:
        // The same one-gap inset in both directions, so the squares start
        // where lined pages start their lines.
        for (double y = spacing; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
        for (double x = spacing; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
      case NotebookRuling.dots:
        // Filled circles at the intersections; fill is the Paint default, so
        // the dots are solid rather than 1 px rings.
        for (double y = spacing; y < size.height; y += spacing) {
          for (double x = spacing; x < size.width; x += spacing) {
            canvas.drawCircle(Offset(x, y), dotRadius, paint);
          }
        }
    }
  }

  @override
  bool shouldRepaint(NotebookRulingPainter oldDelegate) =>
      oldDelegate.ruling != ruling;
}

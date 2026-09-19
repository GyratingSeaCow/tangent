// SPDX-License-Identifier: AGPL-3.0-or-later
/// Page ruling for notebooks.
///
/// Spacing is derived from real ruled-paper standards rather than picked by
/// eye, so the presets mean something physical: on the Tab S10 FE (280 dpi,
/// devicePixelRatio 1.75) one millimetre is 6.3 logical pixels.
///
///   narrow ruled  6.35 mm -> 40 logical px  ("small")
///   college ruled 7.1  mm -> 45 logical px  ("medium")
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
  medium;

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

  /// Gap between rule lines, in logical pixels.
  ///
  /// Zero for [blank], which is what makes "is this page ruled?" a single
  /// question rather than a second flag that can disagree with this one.
  double get lineSpacing => switch (this) {
        NotebookRuling.blank => 0,
        NotebookRuling.small => 40,
        NotebookRuling.medium => 45,
      };

  /// What the picker shows.
  String get label => switch (this) {
        NotebookRuling.blank => 'Blank',
        NotebookRuling.small => 'Lined (small)',
        NotebookRuling.medium => 'Lined (medium)',
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

  /// Deliberately dim. On the near-black page (sunken, #0E1113) this reads as
  /// a guide rather than as content, and it is nowhere near the lime signal
  /// colour, which means "live or selected" everywhere else in this app.
  static const Color lineColor = TangentColors.edge;

  @override
  void paint(Canvas canvas, Size size) {
    final double spacing = ruling.lineSpacing;
    // A zero or non-finite spacing would loop forever. An unbounded parent
    // hands a painter infinite width, which has crashed this app before.
    if (spacing <= 0 || !size.height.isFinite || !size.width.isFinite) return;

    final Paint paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    // Start one full gap down so the first line is not flush against the top
    // edge, where it would read as a border rather than as ruling.
    for (double y = spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(NotebookRulingPainter oldDelegate) =>
      oldDelegate.ruling != ruling;
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

/// Blackout design tokens.
///
/// The app is styled after a field recorder seen at night: a near-black
/// chassis where the only lit things are the signal (lime) and the record key
/// (red). Colour carries meaning here, so the rules below are load-bearing:
///
/// * [signal] marks anything live or selected — the active waveform, the
///   playing row, a selected filter, the pen that is currently armed.
/// * [record] is reserved for capture and destructive confirmation. Nothing
///   else may use it, so red on screen always means one of those two things.
/// * [ink] is handwriting, and is deliberately NOT [signal]: lime ink competes
///   with the transcript and tires the eye over a page of notes.
class TangentColors {
  const TangentColors._();

  /// App background — the chassis.
  static const Color surface = Color(0xFF141719);

  /// Bars, docks and wells: one step below the surface.
  static const Color sunken = Color(0xFF0E1113);

  /// Cards, rows and raised panels: one step above the surface.
  static const Color panel = Color(0xFF1D2124);

  /// Hairline borders and the lit top edge of a panel.
  static const Color edge = Color(0xFF2B3034);

  /// Live/selected accent.
  static const Color signal = Color(0xFFD4FF47);

  /// Capture and destructive actions only.
  static const Color record = Color(0xFFFF3B30);

  /// Primary text.
  static const Color text = Color(0xFFD9DFE3);

  /// Secondary text, inactive icons, metadata.
  static const Color textDim = Color(0xFF8A9299);

  /// Handwriting on the notebook canvas. White, never [signal].
  static const Color ink = Color(0xFFEDF1F3);
}

/// Shape and elevation language.
///
/// Panels are squared enough to read as machined parts; controls are fully
/// round so they look pressable. Elevation is a hard offset with no blur —
/// a blurred shadow immediately reads as a Material card instead of hardware.
class TangentShapes {
  const TangentShapes._();

  static const double panelRadius = 7;
  static const double sheetRadius = 14;
  static const double pillRadius = 999;

  static const double edgeWidth = 1;
  static const double bezelWidth = 3;

  /// Hard drop shadow, no blur. Pair with a lighter top edge for the bevel.
  static const List<BoxShadow> hardDrop = <BoxShadow>[
    BoxShadow(
      color: Color(0xFF070809),
      offset: Offset(0, 3),
      blurRadius: 0,
    ),
  ];

  /// Glow for a LIVE waveform only.
  ///
  /// Never apply this per-row in a list: a glow on every bar of every row
  /// costs real frame time on a long list. One active element at a time.
  static List<BoxShadow> signalGlow({double radius = 5}) => <BoxShadow>[
        BoxShadow(
          color: TangentColors.signal.withValues(alpha: 0.85),
          blurRadius: radius,
        ),
      ];
}

/// Spacing scale. Kept small on purpose — four steps cover the whole app.
class TangentSpacing {
  const TangentSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

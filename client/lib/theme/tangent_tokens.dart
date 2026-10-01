// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

/// Instrument design tokens.
///
/// The app is styled after a field recorder: a machined chassis (Aluminium in
/// the light theme, Anodized in the dark one) with a near-black dot-matrix
/// display window. Colour carries meaning, so the rules below are
/// load-bearing:
///
/// * [TangentPalette.select] (#C4EC42 lime) marks the current page, the
///   playing line, the active word, "Today", live chips and the play key —
///   in BOTH themes. Text and icons on a lime fill are always near-black
///   ([TangentPalette.onSelect]).
/// * [TangentPalette.hot] (#FF4F1F red-orange) is reserved for recording and
///   delete. Nothing else may use it.
/// * Dividers appear only between major regions (sidebar / list / detail).
///   List items are separated by spacing and group headers, never lines.
/// * Status is shown only when actionable (Transcribing, Queued, Failed);
///   "Transcribed" shows nothing.
enum TangentVariant { aluminium, anodized }

/// Theme-dependent colours, carried as a [ThemeExtension] so widgets can
/// resolve them from context: `TangentPalette.of(context)`.
///
/// Values are lifted verbatim from the approved mockup
/// (`tangent-redesign/src/i2-screens.js`, `.ki` / `.ki.v-anod` custom
/// properties).
@immutable
class TangentPalette extends ThemeExtension<TangentPalette> {
  const TangentPalette({
    required this.brightness,
    required this.chassis,
    required this.chassisDeep,
    required this.panel,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.seam,
    required this.display,
    required this.displayDot,
    required this.displayOff,
    required this.displayRest,
    required this.select,
    required this.selectTint,
    required this.onSelect,
    required this.hot,
  });

  /// Aluminium — the light chassis.
  static const TangentPalette aluminium = TangentPalette(
    brightness: Brightness.light,
    chassis: Color(0xFFE7E5E0),
    chassisDeep: Color(0xFFDDDAD4),
    panel: Color(0xFFF3F1ED),
    ink: Color(0xFF161616),
    inkMuted: Color(0xFF5F5C56),
    inkFaint: Color(0xFF8E8A82),
    seam: Color(0x17161616), // rgba(22,22,22,.09)
    display: Color(0xFF111111),
    displayDot: Color(0xFFF2EFE6),
    displayOff: Color(0xFF1F1F1F),
    displayRest: Color(0xFF46443F),
    select: Color(0xFFC4EC42),
    selectTint: Color(0x4DC4EC42), // rgba(196,236,66,.30)
    onSelect: Color(0xFF111111),
    hot: Color(0xFFFF4F1F),
  );

  /// Anodized — the dark chassis. Default theme.
  static const TangentPalette anodized = TangentPalette(
    brightness: Brightness.dark,
    chassis: Color(0xFF141414),
    chassisDeep: Color(0xFF1B1B1B),
    panel: Color(0xFF1F1F1F),
    ink: Color(0xFFECEAE4),
    inkMuted: Color(0xFFA3A097),
    inkFaint: Color(0xFF6F6C66),
    seam: Color(0x12FFFFFF), // rgba(255,255,255,.07)
    display: Color(0xFF070707),
    displayDot: Color(0xFFF2EFE6),
    displayOff: Color(0xFF161616),
    displayRest: Color(0xFF3D3B37),
    select: Color(0xFFC4EC42),
    selectTint: Color(0x21C4EC42), // rgba(196,236,66,.13)
    onSelect: Color(0xFF111111),
    hot: Color(0xFFFF4F1F),
  );

  static TangentPalette variant(TangentVariant v) => switch (v) {
        TangentVariant.aluminium => aluminium,
        TangentVariant.anodized => anodized,
      };

  /// Resolve the palette from the ambient theme. Falls back to [anodized]
  /// when the extension is missing (tests building bare ThemeData).
  static TangentPalette of(BuildContext context) =>
      Theme.of(context).extension<TangentPalette>() ?? anodized;

  final Brightness brightness;

  /// App background — the chassis.
  final Color chassis;

  /// One step off the chassis: hover fills, wells, pressed keys.
  final Color chassisDeep;

  /// Keys, rows, cards, raised panels.
  final Color panel;

  /// Primary text and icons.
  final Color ink;

  /// Secondary text, inactive icons.
  final Color inkMuted;

  /// Metadata, small-caps labels, the quietest text.
  final Color inkFaint;

  /// Hairline between major regions ONLY (sidebar / list / detail).
  final Color seam;

  /// The dot-matrix display window background.
  final Color display;

  /// Lit dots on the display (warm white in both themes).
  final Color displayDot;

  /// Unlit dots on the display.
  final Color displayOff;

  /// Dimmed/resting dots (idle waveform, elapsed scrubber).
  final Color displayRest;

  /// Select — current page, playing line, active word, "Today", live chips,
  /// play key. #C4EC42 in both themes.
  final Color select;

  /// Translucent select wash for active paragraph/row backgrounds.
  final Color selectTint;

  /// Text/icons on a [select] fill. Always near-black.
  final Color onSelect;

  /// Recording and delete ONLY.
  final Color hot;

  @override
  TangentPalette copyWith({
    Brightness? brightness,
    Color? chassis,
    Color? chassisDeep,
    Color? panel,
    Color? ink,
    Color? inkMuted,
    Color? inkFaint,
    Color? seam,
    Color? display,
    Color? displayDot,
    Color? displayOff,
    Color? displayRest,
    Color? select,
    Color? selectTint,
    Color? onSelect,
    Color? hot,
  }) {
    return TangentPalette(
      brightness: brightness ?? this.brightness,
      chassis: chassis ?? this.chassis,
      chassisDeep: chassisDeep ?? this.chassisDeep,
      panel: panel ?? this.panel,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      inkFaint: inkFaint ?? this.inkFaint,
      seam: seam ?? this.seam,
      display: display ?? this.display,
      displayDot: displayDot ?? this.displayDot,
      displayOff: displayOff ?? this.displayOff,
      displayRest: displayRest ?? this.displayRest,
      select: select ?? this.select,
      selectTint: selectTint ?? this.selectTint,
      onSelect: onSelect ?? this.onSelect,
      hot: hot ?? this.hot,
    );
  }

  @override
  TangentPalette lerp(ThemeExtension<TangentPalette>? other, double t) {
    if (other is! TangentPalette) return this;
    return TangentPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      chassis: Color.lerp(chassis, other.chassis, t)!,
      chassisDeep: Color.lerp(chassisDeep, other.chassisDeep, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      inkFaint: Color.lerp(inkFaint, other.inkFaint, t)!,
      seam: Color.lerp(seam, other.seam, t)!,
      display: Color.lerp(display, other.display, t)!,
      displayDot: Color.lerp(displayDot, other.displayDot, t)!,
      displayOff: Color.lerp(displayOff, other.displayOff, t)!,
      displayRest: Color.lerp(displayRest, other.displayRest, t)!,
      select: Color.lerp(select, other.select, t)!,
      selectTint: Color.lerp(selectTint, other.selectTint, t)!,
      onSelect: Color.lerp(onSelect, other.onSelect, t)!,
      hot: Color.lerp(hot, other.hot, t)!,
    );
  }
}

/// LEGACY static colours, remapped to the Anodized instrument palette.
///
/// Existing screens reference these statics directly; they keep compiling and
/// pick up the new palette, but new/restyled code should resolve
/// [TangentPalette.of] instead so it follows the active theme (Aluminium or
/// Anodized). Delete members as their last consumer migrates.
class TangentColors {
  const TangentColors._();

  /// App background — the chassis. LEGACY: use [TangentPalette.chassis].
  static const Color surface = Color(0xFF141414);

  /// Wells and text-on-lime. LEGACY: use [TangentPalette.onSelect] for text
  /// on a select fill, [TangentPalette.display] for sunken wells.
  static const Color sunken = Color(0xFF111111);

  /// Cards, rows and raised panels. LEGACY: use [TangentPalette.panel].
  static const Color panel = Color(0xFF1F1F1F);

  /// Hairline borders. LEGACY: use [TangentPalette.seam] (and only between
  /// major regions — never between list items).
  static const Color edge = Color(0xFF242424);

  /// Notebook ruling — lines, graph grid and dot grid on the page.
  ///
  /// Brighter than [edge] on purpose: ruling has to be FOLLOWED by a hand
  /// holding a stylus, so it sits near 2.9:1 against the page — clearly
  /// visible, still far below the ink so handwriting dominates.
  static const Color rule = Color(0xFF615E56);

  /// Select accent. LEGACY: use [TangentPalette.select].
  static const Color signal = Color(0xFFC4EC42);

  /// Recording and delete only. LEGACY: use [TangentPalette.hot].
  static const Color record = Color(0xFFFF4F1F);

  /// Primary text. LEGACY: use [TangentPalette.ink].
  static const Color text = Color(0xFFECEAE4);

  /// Secondary text, inactive icons. LEGACY: use [TangentPalette.inkMuted].
  static const Color textDim = Color(0xFFA3A097);

  /// Handwriting on the notebook canvas. Warm white, never [signal]: lime
  /// ink competes with the transcript and tires the eye over a page.
  static const Color ink = Color(0xFFF2EFE6);

  /// Morning-review daybreak accents (Ask-arc queued item 2). Light blue
  /// is the START-OF-DAY signal, chosen by Jeff and load-bearing like the
  /// other colours here: it appears on exactly one surface — the morning
  /// review card — so a light-blue panel always means "your yesterday".
  /// The face is deliberately LIGHT on the dark chassis (the one lit
  /// card at dawn), so its text needs its own dark ink values.
  static const Color daybreak = Color(0xFFBFE0FA);

  /// Lit top edge of the daybreak panel (same bevel language as [edge]).
  static const Color daybreakEdge = Color(0xFFE4F2FF);

  /// Primary text on [daybreak].
  static const Color daybreakInk = Color(0xFF12283A);

  /// Secondary text and icons on [daybreak].
  static const Color daybreakInkDim = Color(0xFF3D5A73);
}

/// Shape language. Radius on everything — never square, never pills.
///
/// The four-step scale is approved as-is: 4 / 8 / 12 / 18.
class TangentShapes {
  const TangentShapes._();

  /// Tags, checkboxes, small chips.
  static const double radiusTag = 4;

  /// Keys, buttons, inputs, list rows.
  static const double radiusControl = 8;

  /// Display window, panels, cards, covers.
  static const double radiusPanel = 12;

  /// Sheets and dialogs.
  static const double radiusSheet = 18;

  /// LEGACY alias — most consumers used this on buttons/inputs/rows.
  /// Migrate to [radiusControl] (or [radiusPanel] for true panels).
  static const double panelRadius = radiusControl;

  /// LEGACY alias for [radiusSheet].
  static const double sheetRadius = radiusSheet;

  /// LEGACY. Pills are rejected in the Instrument language — replace with
  /// [radiusControl] (or [radiusPanel] on large keys) as screens migrate.
  @Deprecated('Never pills: use radiusControl / radiusPanel instead')
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

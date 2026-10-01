// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import 'tangent_tokens.dart';

/// The Instrument theme.
///
/// Two chassis finishes exist — Aluminium (light) and Anodized (dark) — and
/// both use the same lime [TangentPalette.select] and red-orange
/// [TangentPalette.hot]. Anodized is the default. `tangentTheme()` with no
/// argument keeps the legacy single-theme call sites working.
ThemeData tangentTheme([TangentVariant variant = TangentVariant.anodized]) {
  final p = TangentPalette.variant(variant);
  final dark = p.brightness == Brightness.dark;

  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.select,
    onPrimary: p.onSelect,
    secondary: p.select,
    onSecondary: p.onSelect,
    secondaryContainer: p.select,
    onSecondaryContainer: p.onSelect,
    surface: p.chassis,
    onSurface: p.ink,
    surfaceContainerHighest: p.panel,
    error: p.hot,
    onError: dark ? p.ink : const Color(0xFFFFFFFF),
    outline: p.seam,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
  );

  RoundedRectangleBorder rounded(double r, [BorderSide side = BorderSide.none]) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r),
        side: side,
      );

  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[p],
    scaffoldBackgroundColor: p.chassis,
    canvasColor: p.chassis,
    // Dividers exist only between major regions (sidebar / list / detail).
    // Never put one between list items — use spacing and group headers.
    dividerColor: p.seam,
    dividerTheme: DividerThemeData(
      color: p.seam,
      thickness: TangentShapes.edgeWidth,
      space: TangentShapes.edgeWidth,
    ),
    // Headers sit directly on the chassis; the seam below is the only line.
    appBarTheme: AppBarTheme(
      backgroundColor: p.chassis,
      foregroundColor: p.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(
        bottom: BorderSide(color: p.seam, width: TangentShapes.edgeWidth),
      ),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rounded(
        TangentShapes.radiusPanel,
        BorderSide(color: p.seam, width: TangentShapes.edgeWidth),
      ),
    ),
    // The record key. Hot, and the only FAB in the app. Rounded, not a pill.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.hot,
      foregroundColor: const Color(0xFFFFFFFF),
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: rounded(TangentShapes.radiusPanel),
    ),
    // Tags/chips: 4px radius, never stadium.
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: p.select,
      checkmarkColor: p.onSelect,
      labelStyle: TextStyle(
        color: p.inkMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: TextStyle(
        color: p.onSelect,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide(color: p.seam),
      shape: rounded(TangentShapes.radiusTag),
      showCheckmark: false,
    ),
    listTileTheme: ListTileThemeData(
      textColor: p.ink,
      iconColor: p.inkMuted,
      selectedColor: p.select,
      shape: rounded(TangentShapes.radiusControl),
    ),
    iconTheme: IconThemeData(color: p.inkMuted),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        shape: rounded(TangentShapes.radiusControl),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.select,
        foregroundColor: p.onSelect,
        shape: rounded(TangentShapes.radiusControl),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.seam),
        shape: rounded(TangentShapes.radiusControl),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TangentShapes.radiusSheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: rounded(TangentShapes.radiusSheet),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.panel,
      contentTextStyle: TextStyle(color: p.ink),
      actionTextColor: p.select,
      behavior: SnackBarBehavior.floating,
      shape: rounded(TangentShapes.radiusControl),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.select,
      linearTrackColor: p.chassisDeep,
      circularTrackColor: p.chassisDeep,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.select,
      inactiveTrackColor: p.chassisDeep,
      thumbColor: p.select,
      trackHeight: 3,
      overlayColor: Colors.transparent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? p.onSelect : p.inkMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? p.select : p.chassisDeep,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : p.seam,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.select
            : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(p.onSelect),
      side: BorderSide(color: p.inkFaint, width: 1.5),
      shape: rounded(TangentShapes.radiusTag),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel,
      hintStyle: TextStyle(color: p.inkFaint),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TangentShapes.radiusControl),
        borderSide: BorderSide(color: p.seam),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TangentShapes.radiusControl),
        borderSide: BorderSide(color: p.seam),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TangentShapes.radiusControl),
        borderSide: BorderSide(color: p.select),
      ),
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: p.ink,
          displayColor: p.ink,
        )
        .copyWith(
          labelSmall: TextStyle(
            color: p.inkFaint,
            fontSize: 10,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
  );
}

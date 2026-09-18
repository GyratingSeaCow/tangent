// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import 'tangent_tokens.dart';

/// The Blackout theme.
///
/// Tangent ships one theme. The app is a recording instrument, and an
/// instrument does not change colour with the system setting — so there is no
/// light variant and [ThemeMode.dark] is pinned in `main.dart`.
ThemeData tangentTheme() {
  const scheme = ColorScheme.dark(
    primary: TangentColors.signal,
    onPrimary: TangentColors.sunken,
    secondary: TangentColors.signal,
    onSecondary: TangentColors.sunken,
    surface: TangentColors.surface,
    onSurface: TangentColors.text,
    error: TangentColors.record,
    onError: TangentColors.text,
    outline: TangentColors.edge,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: TangentColors.surface,
    canvasColor: TangentColors.surface,
    dividerColor: TangentColors.edge,
    dividerTheme: const DividerThemeData(
      color: TangentColors.edge,
      thickness: TangentShapes.edgeWidth,
      space: TangentShapes.edgeWidth,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: TangentColors.sunken,
      foregroundColor: TangentColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(
        bottom: BorderSide(
          color: TangentColors.edge,
          width: TangentShapes.edgeWidth,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: TangentColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
        side: const BorderSide(
          color: TangentColors.edge,
          width: TangentShapes.edgeWidth,
        ),
      ),
    ),
    // The record key. Red, fully round, and the only FAB in the app.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: TangentColors.record,
      foregroundColor: TangentColors.sunken,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TangentShapes.pillRadius),
        side: const BorderSide(
          color: TangentColors.edge,
          width: TangentShapes.bezelWidth,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: TangentColors.signal,
      checkmarkColor: TangentColors.sunken,
      labelStyle: const TextStyle(
        color: TangentColors.textDim,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: const TextStyle(
        color: TangentColors.sunken,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
      side: const BorderSide(color: TangentColors.edge),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    listTileTheme: const ListTileThemeData(
      textColor: TangentColors.text,
      iconColor: TangentColors.textDim,
      selectedColor: TangentColors.signal,
    ),
    iconTheme: const IconThemeData(color: TangentColors.textDim),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: TangentColors.signal),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TangentColors.signal,
        foregroundColor: TangentColors.sunken,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TangentColors.signal,
        side: const BorderSide(color: TangentColors.edge),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
        ),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: TangentColors.sunken,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TangentShapes.sheetRadius),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: TangentColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TangentShapes.sheetRadius),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: TangentColors.panel,
      contentTextStyle: const TextStyle(color: TangentColors.text),
      actionTextColor: TangentColors.signal,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: TangentColors.signal,
      linearTrackColor: TangentColors.edge,
      circularTrackColor: TangentColors.edge,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: TangentColors.signal,
      inactiveTrackColor: TangentColors.edge,
      thumbColor: TangentColors.signal,
      trackHeight: 3,
      overlayColor: Colors.transparent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? TangentColors.signal
            : TangentColors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? TangentColors.signal.withValues(alpha: 0.28)
            : TangentColors.edge,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? TangentColors.signal
            : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(TangentColors.sunken),
      side: const BorderSide(color: TangentColors.edge, width: 1.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: TangentColors.sunken,
      hintStyle: const TextStyle(color: TangentColors.textDim),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
        borderSide: const BorderSide(color: TangentColors.edge),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
        borderSide: const BorderSide(color: TangentColors.edge),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(TangentShapes.panelRadius),
        borderSide: const BorderSide(color: TangentColors.signal),
      ),
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: TangentColors.text,
          displayColor: TangentColors.text,
        )
        .copyWith(
          labelSmall: const TextStyle(
            color: TangentColors.textDim,
            fontSize: 10,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
  );
}

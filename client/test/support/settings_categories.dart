// SPDX-License-Identifier: AGPL-3.0-or-later
/// Instrument Console v2 Settings helpers: the flat list became nine
/// in-place drills, so a test that wants a control first opens its
/// category. The screen stays ONE widget/State; nothing is pushed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/settings/settings_screen.dart';

/// Open [category] from the overview. Pumps discretely (never
/// pumpAndSettle: several section widgets run timers/streams).
Future<void> openSettingsCategory(
  WidgetTester tester,
  SettingsCategory category,
) async {
  final Finder row = find.byKey(SettingsScreen.categoryKey(category));
  await tester.scrollUntilVisible(
    row,
    80,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(row);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Return from a drill to the overview via the app bar's back arrow.
Future<void> closeSettingsCategory(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('settings-category-back')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

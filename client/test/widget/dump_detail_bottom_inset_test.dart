// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The recording screen's action row is the LAST child of a scrolling list,
// so nothing below it pushes it clear of the system navigation bar. On the
// Fold the taskbar is tall enough to swallow "Save" almost entirely, which
// is exactly what shipped before this was pinned.
//
// These tests assert the scroll view RESERVES the bottom inset, which is the
// behaviour a screenshot would show: the buttons end above the system bar.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart'
    show actionRowSafePadding;

// NOTE: this imports the REAL helper the screen uses. Re-declaring the rule
// here would let production drift while the test stayed green.

Future<EdgeInsets> _paddingUnder(
  WidgetTester tester, {
  required double bottomInset,
  double keyboardInset = 0,
}) async {
  late EdgeInsets captured;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        viewPadding: EdgeInsets.only(bottom: bottomInset),
        padding: EdgeInsets.only(
          // Flutter zeroes `padding` where the keyboard covers the inset;
          // viewPadding keeps reporting it. Model that here.
          bottom: keyboardInset > 0 ? 0 : bottomInset,
        ),
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
      ),
      child: Builder(
        builder: (BuildContext context) {
          captured = actionRowSafePadding(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('the action row reserves the system bar height below itself',
      (WidgetTester tester) async {
    // A Fold-class taskbar, the case Jeff hit.
    final EdgeInsets padding = await _paddingUnder(tester, bottomInset: 48);

    expect(
      padding.bottom,
      64,
      reason: '16 of breathing room PLUS the 48 the system bar occupies — '
          'without this the taskbar sits on Save and Transcribe again',
    );
    expect(padding.left, 16);
    expect(padding.right, 16);
    expect(padding.top, 16);
  });

  testWidgets('a device with no bottom inset keeps the original padding',
      (WidgetTester tester) async {
    final EdgeInsets padding = await _paddingUnder(tester, bottomInset: 0);

    expect(
      padding,
      const EdgeInsets.all(16),
      reason: 'desktop and button-nav devices must look exactly as before',
    );
  });

  testWidgets('the reservation survives the keyboard opening',
      (WidgetTester tester) async {
    // Focusing the title editor raises the keyboard. If this read `padding`
    // instead of `viewPadding` the reservation would collapse to 16 and the
    // buttons would jump down behind the bar mid-edit.
    final EdgeInsets padding = await _paddingUnder(
      tester,
      bottomInset: 48,
      keyboardInset: 300,
    );

    expect(padding.bottom, 64);
  });
}

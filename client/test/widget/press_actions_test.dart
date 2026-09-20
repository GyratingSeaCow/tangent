// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/press_actions.dart';

/// Desktop parity for the app's long-press gesture: a mouse right-click
/// (secondary button) must do exactly what a long-press does, everywhere a
/// long-press means something. [pressActions] is the one seam every list
/// row/header goes through, so this unit-level contract covers the shared
/// behavior; per-screen wiring is covered by the list widget tests.
void main() {
  Widget host({VoidCallback? onPress}) {
    return MaterialApp(
      home: Scaffold(
        body: Material(
          child: InkWell(
            key: const ValueKey('target'),
            onTap: () {},
            onLongPress: onPress,
            onSecondaryTap: secondaryTapFor(onPress),
            child: const SizedBox(width: 200, height: 60),
          ),
        ),
      ),
    );
  }

  testWidgets('right-click fires the long-press action', (tester) async {
    var fired = 0;
    await tester.pumpWidget(host(onPress: () => fired++));

    final center = tester.getCenter(find.byKey(const ValueKey('target')));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();

    expect(fired, 1);
  });

  testWidgets('null action means right-click is inert, like long-press',
      (tester) async {
    await tester.pumpWidget(host(onPress: null));
    expect(
      secondaryTapFor(null),
      isNull,
      reason: 'a disabled long-press must not leave a live right-click',
    );

    final center = tester.getCenter(find.byKey(const ValueKey('target')));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('left-click still taps, not the long-press action',
      (tester) async {
    var pressed = 0;
    await tester.pumpWidget(host(onPress: () => pressed++));
    await tester.tap(find.byKey(const ValueKey('target')));
    await tester.pump();
    expect(pressed, 0);
  });
}

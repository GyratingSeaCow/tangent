// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/widgets/mouse_back_navigation.dart';

/// Desktop: the mouse's back side-button (button 8) navigates back, exactly
/// like the AppBar's back arrow. Routed through Navigator.maybePop so
/// PopScope handlers (the notebook editor's save-on-back) still run —
/// a hardware back that skipped saving would be data loss.
///
/// Two delivery paths, both covered here:
/// - pointer events carrying kBackMouseButton (Windows; also how tests
///   drive it)
/// - the 'back' method call from the Linux GTK runner, which must exist
///   because Flutter's GTK embedder forwards only buttons 1-3 — side
///   buttons never reach the Dart pointer stream on Linux (verified with
///   a live probe: pressing back produced no PointerDownEvent at all).
void main() {
  Widget app(GlobalKey<NavigatorState> navigator) {
    return MouseBackNavigation(
      navigatorKey: navigator,
      child: MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('push'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Text('second screen'),
                  ),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pressBackButton(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      const Offset(400, 300),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Injects the platform-side 'back' call the GTK runner sends.
  Future<void> nativeBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'tangent/mouse_navigation',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('back')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the native back channel pops the current route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(app(navigator));

    await tester.tap(find.byKey(const ValueKey('push')));
    await tester.pumpAndSettle();
    expect(find.text('second screen'), findsOneWidget);

    await nativeBack(tester);

    expect(
      find.text('second screen'),
      findsNothing,
      reason: 'the GTK runner back call must pop, like the AppBar arrow',
    );
  });

  testWidgets('mouse back button pops the current route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(app(navigator));

    await tester.tap(find.byKey(const ValueKey('push')));
    await tester.pumpAndSettle();
    expect(find.text('second screen'), findsOneWidget);

    await pressBackButton(tester);

    expect(
      find.text('second screen'),
      findsNothing,
      reason: 'mouse back must pop, like the AppBar arrow',
    );
    expect(find.byKey(const ValueKey('push')), findsOneWidget);
  });

  testWidgets('on the root route the back button is a no-op, not a crash',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(app(navigator));

    await pressBackButton(tester);

    expect(find.byKey(const ValueKey('push')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a PopScope veto is honored (save-on-back keeps its say)',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    var vetoed = 0;
    await tester.pumpWidget(
      MouseBackNavigation(
        navigatorKey: navigator,
        child: MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('push'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PopScope(
                      canPop: false,
                      onPopInvokedWithResult: (didPop, _) {
                        if (!didPop) vetoed++;
                      },
                      child: const Scaffold(body: Text('guarded screen')),
                    ),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('push')));
    await tester.pumpAndSettle();

    await pressBackButton(tester);

    expect(
      find.text('guarded screen'),
      findsOneWidget,
      reason: 'PopScope(canPop: false) must veto the hardware back too',
    );
    expect(vetoed, 1, reason: 'the guard must have been consulted');
  });
}

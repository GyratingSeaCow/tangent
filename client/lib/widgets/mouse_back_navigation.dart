// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Mouse back-button navigation for desktop.
///
/// The thumb button (button 8, [kBackMouseButton]) does what the AppBar's
/// back arrow does: pop the current route. Wraps the whole app in a
/// [Listener] — pointer *events* reach it regardless of what widget the
/// cursor happens to be over, so back works from anywhere on any screen.
///
/// Routed through [NavigatorState.maybePop], never pop(): the notebook
/// editor guards leaving with PopScope to run save-on-back, and a hardware
/// back that bypassed that guard would silently discard edits. maybePop
/// consults the guard exactly like the AppBar arrow; on the root route it
/// is a no-op.
class MouseBackNavigation extends StatelessWidget {
  const MouseBackNavigation({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// The app's root navigator — the same one MaterialApp uses.
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons & kBackMouseButton == 0) return;
    navigatorKey.currentState?.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      child: child,
    );
  }
}

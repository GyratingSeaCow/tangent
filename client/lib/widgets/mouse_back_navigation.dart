// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Mouse back-button navigation for desktop.
///
/// The thumb button (button 8) does what the AppBar's back arrow does:
/// pop the current route. Two delivery paths feed the same maybePop:
///
/// - Pointer events carrying [kBackMouseButton] (Windows embedder; also
///   how widget tests drive it).
/// - A 'back' method call on the `tangent/mouse_navigation` channel from
///   the Linux GTK runner. Necessary because Flutter's GTK embedder
///   forwards only buttons 1-3 to Dart — side buttons never appear in the
///   pointer stream at all (verified with a live probe on KDE Wayland:
///   pressing back produced no PointerDownEvent). The runner listens for
///   GDK button 8 on the window and calls through.
///
/// Routed through [NavigatorState.maybePop], never pop(): the notebook
/// editor guards leaving with PopScope to run save-on-back, and a hardware
/// back that bypassed that guard would silently discard edits. maybePop
/// consults the guard exactly like the AppBar arrow; on the root route it
/// is a no-op.
class MouseBackNavigation extends StatefulWidget {
  const MouseBackNavigation({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// The app's root navigator — the same one MaterialApp uses.
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  @override
  State<MouseBackNavigation> createState() => _MouseBackNavigationState();
}

class _MouseBackNavigationState extends State<MouseBackNavigation> {
  static const MethodChannel _channel =
      MethodChannel('tangent/mouse_navigation');

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onMethodCall);
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method == 'back') _goBack();
    return null;
  }

  void _goBack() {
    widget.navigatorKey.currentState?.maybePop();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons & kBackMouseButton == 0) return;
    _goBack();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      child: widget.child,
    );
  }
}

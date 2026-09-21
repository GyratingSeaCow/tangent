// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:window_manager/window_manager.dart';

/// Close-to-tray: the X button hides the window; the tray owns quitting.
///
/// Discord-style lifecycle. Tangent lives in the tray, so closing the
/// window should park the app there — a brain-dump tool you have to
/// relaunch before every thought defeats its own purpose (and the global
/// hotkey needs a living instance to talk to). The one true quit is the
/// tray's Exit item, which calls [exitForReal].
///
/// Decision logic takes its window operations by injection; [install]
/// is the only part that touches window_manager.
class CloseToTray with WindowListener {
  CloseToTray({
    required Future<void> Function() hideWindow,
    required Future<void> Function() quitApp,
  })  : _hideWindow = hideWindow,
        _quitApp = quitApp;

  final Future<void> Function() _hideWindow;
  final Future<void> Function() _quitApp;

  /// The X button (or Alt+F4): hide to the tray, never quit.
  Future<void> onCloseRequested() => _hideWindow();

  /// Tray Exit: a real quit that bypasses close-to-tray.
  Future<void> exitForReal() => _quitApp();

  // ---- window_manager integration (exercised live, not unit-tested) ----

  /// Arms close interception: the native close becomes a callback to
  /// [onCloseRequested] instead of destroying the window.
  Future<void> install() async {
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
  }

  @override
  void onWindowClose() {
    unawaited(onCloseRequested());
  }
}

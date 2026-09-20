// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

/// One tray menu row: stable key + visible label.
class TrayMenuItem {
  const TrayMenuItem({required this.key, required this.label});

  final String key;
  final String label;
}

/// The system tray icon: Tangent living in the bottom-right, Discord-style.
///
/// The menu contract is deliberately tiny — Open App, Start Recording,
/// Exit — and the click handling is pure logic behind a seam so tests can
/// drive it without the tray_manager platform channel. [install] is the
/// only method that touches the real plugin.
class TrayService with tray.TrayListener {
  TrayService({
    required Future<void> Function() onOpenApp,
    required Future<void> Function() onStartRecording,
    required Future<void> Function() onExit,
  })  : _onOpenApp = onOpenApp,
        _onStartRecording = onStartRecording,
        _onExit = onExit;

  static const String openAppKey = 'open-app';
  static const String startRecordingKey = 'start-recording';
  static const String exitKey = 'exit';

  static const List<TrayMenuItem> menuItems = [
    TrayMenuItem(key: openAppKey, label: 'Open App'),
    TrayMenuItem(key: startRecordingKey, label: 'Start Recording'),
    TrayMenuItem(key: exitKey, label: 'Exit'),
  ];

  final Future<void> Function() _onOpenApp;
  final Future<void> Function() _onStartRecording;
  final Future<void> Function() _onExit;

  /// Dispatches one menu click. Unknown keys are ignored: a stale menu from
  /// a half-updated tray must never crash the app.
  Future<void> handleMenuClick(String key) async {
    switch (key) {
      case openAppKey:
        await _onOpenApp();
      case startRecordingKey:
        await _onStartRecording();
      case exitKey:
        await _onExit();
    }
  }

  /// A plain left-click on the icon: open the app, same as Discord.
  Future<void> handleIconClick() => _onOpenApp();

  // ---- tray_manager integration (not unit-tested; exercised live) ----

  /// Puts the icon in the tray and wires the context menu.
  Future<void> install() async {
    await tray.trayManager.setIcon('assets/tray/tray_icon.png');
    // No setToolTip here: tray_manager's Linux plugin doesn't implement it
    // (appindicators have no tooltip), and the MissingPluginException would
    // abort install before the menu is wired.
    await tray.trayManager.setContextMenu(
      tray.Menu(
        items: [
          for (final item in menuItems)
            tray.MenuItem(key: item.key, label: item.label),
        ],
      ),
    );
    tray.trayManager.addListener(this);
  }

  Future<void> dispose() async {
    tray.trayManager.removeListener(this);
    await tray.trayManager.destroy();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(handleIconClick());
  }

  @override
  void onTrayIconRightMouseDown() {
    // KDE's StatusNotifierItem shows the context menu on right-click by
    // itself; this hook exists for platforms that don't.
    unawaited(tray.trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    final key = menuItem.key;
    if (key != null) unawaited(handleMenuClick(key));
  }
}

/// Brings the app window to the front (or back from minimized).
Future<void> raiseAppWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

/// Quits the whole app from the tray.
Future<void> exitApp() async {
  await windowManager.destroy();
  exit(0);
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:window_manager/window_manager.dart';

import 'sni_tray.dart';

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
/// drive it without a bus. [install] is the only method that touches D-Bus.
///
/// Click contract: LEFT click activates (opens the app), RIGHT click shows
/// the menu. This rules out libappindicator (tray_manager's backend),
/// which hardcodes ItemIsMenu=true and turns left-click into the menu too;
/// instead the tray speaks StatusNotifierItem directly (see sni_tray.dart).
class TrayService {
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

  // ---- D-Bus integration (protocol logic tested in sni_tray_test) ----

  SniTray? _sni;

  /// Puts the icon in the tray and wires the context menu.
  Future<void> install() async {
    final iconBytes = await rootBundle.load('assets/tray/tray_icon.png');
    final iconDir = await materializeTrayIcon(iconBytes.buffer.asUint8List());
    final sni = SniTray(service: this);
    _sni = sni;
    await sni.install(iconDir: iconDir);
  }

  Future<void> dispose() async {
    await _sni?.dispose();
    _sni = null;
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

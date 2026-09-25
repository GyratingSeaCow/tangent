// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:tray_manager/tray_manager.dart' as tm;

import 'tray_service.dart';

/// Windows tray backend: Shell_NotifyIcon via tray_manager.
///
/// Unlike the Linux GTK backend (libappindicator, which forces the menu on
/// left-click), the Windows notification-area API keeps left-click and
/// right-click distinct, so tray_manager delivers exactly the click
/// contract TrayService promises: left activates, right menus.
///
/// All decisions stay in TrayService; this class only translates platform
/// events into the same handleIconClick/handleMenuClick calls the SNI
/// backend makes, so the tested logic is shared.
class WinTray with tm.TrayListener {
  WinTray({required this.service});

  final TrayService service;

  /// Puts the icon in the notification area and attaches the menu.
  ///
  /// [iconAssetPath] is a Flutter asset path to a real .ico —
  /// tray_manager resolves it against the bundle's flutter_assets dir and
  /// hands the resulting file to Shell_NotifyIcon.
  Future<void> install({required String iconAssetPath}) async {
    tm.trayManager.addListener(this);
    await tm.trayManager.setIcon(iconAssetPath);
    await tm.trayManager.setToolTip('Tangent');
    await tm.trayManager.setContextMenu(
      tm.Menu(
        items: [
          for (final item in TrayService.menuItems)
            tm.MenuItem(key: item.key, label: item.label),
        ],
      ),
    );
  }

  @override
  void onTrayIconMouseDown() => service.handleIconClick();

  @override
  void onTrayIconRightMouseDown() => tm.trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(tm.MenuItem menuItem) {
    final key = menuItem.key;
    if (key != null) service.handleMenuClick(key);
  }

  Future<void> dispose() async {
    tm.trayManager.removeListener(this);
    await tm.trayManager.destroy();
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/sni_tray.dart';
import 'package:tangent/services/tray_service.dart';

/// The Linux tray speaks StatusNotifierItem + com.canonical.dbusmenu over
/// D-Bus directly (libappindicator hardcodes ItemIsMenu=true, which makes
/// KDE open the menu on LEFT click too — the opposite of the required
/// behavior). These tests pin the protocol pieces that encode the click
/// contract: ItemIsMenu=false, Activate = open app, menu ids = handlers.
void main() {
  TrayService service({List<String>? log}) => TrayService(
        onOpenApp: () async => log?.add('open'),
        onStartRecording: () async => log?.add('record'),
        onExit: () async => log?.add('exit'),
      );

  test('ItemIsMenu is false: left-click must activate, not open the menu', () {
    final item = StatusNotifierItemObject(
      service: service(),
      iconName: 'tangent',
      iconThemePath: '/tmp/icons',
    );
    expect(item.itemIsMenu, isFalse);
  });

  test('Activate opens the app', () async {
    final log = <String>[];
    final item = StatusNotifierItemObject(
      service: service(log: log),
      iconName: 'tangent',
      iconThemePath: '/tmp/icons',
    );
    await item.activate(0, 0);
    expect(log, ['open']);
  });

  test('dbusmenu layout lists Open App / Start Recording / Exit in order', () {
    final menu = DbusMenuObject(service: service());
    final layout = menu.buildLayout();
    // (id, properties, children) triple for the root; children carry the
    // items.
    final children = (layout.children[2] as DBusArray)
        .children
        .map((v) => (v as DBusVariant).value as DBusStruct)
        .toList();
    final labels = children.map((item) {
      final props = (item.children[1] as DBusDict).children;
      return (props[const DBusString('label')]! as DBusVariant).value;
    }).toList();
    expect(labels, [
      const DBusString('Open App'),
      const DBusString('Start Recording'),
      const DBusString('Exit'),
    ]);
  });

  test('menu Event dispatches clicks to the right handler', () async {
    final log = <String>[];
    final menu = DbusMenuObject(service: service(log: log));
    await menu.handleEvent(1, 'clicked'); // Open App
    await menu.handleEvent(2, 'clicked'); // Start Recording
    await menu.handleEvent(3, 'clicked'); // Exit
    expect(log, ['open', 'record', 'exit']);
  });

  test('unknown ids and non-click events are ignored', () async {
    final log = <String>[];
    final menu = DbusMenuObject(service: service(log: log));
    await menu.handleEvent(99, 'clicked');
    await menu.handleEvent(1, 'hovered');
    expect(log, isEmpty);
  });
}

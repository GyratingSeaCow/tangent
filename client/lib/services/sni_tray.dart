// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'tray_service.dart';

/// StatusNotifierItem + com.canonical.dbusmenu, spoken directly over D-Bus.
///
/// Why not libappindicator (tray_manager's backend): it hardcodes
/// `ItemIsMenu = true`, which tells KDE "this item is only a menu" — so a
/// LEFT click opens the context menu instead of activating the app. The
/// required behavior is the Discord split: left-click opens the window,
/// right-click shows the menu. That needs `ItemIsMenu = false` plus a real
/// `Activate` implementation, which the appindicator API cannot express.
///
/// Protocol shape (KDE watches these):
/// - org.kde.StatusNotifierItem on /StatusNotifierItem: properties
///   (IconName, ItemIsMenu, Menu…), Activate(), ContextMenu().
/// - com.canonical.dbusmenu on /MenuBar: GetLayout() + Event() carry the
///   right-click menu.
/// - Registration with org.kde.StatusNotifierWatcher.

/// The /StatusNotifierItem object.
class StatusNotifierItemObject extends DBusObject {
  StatusNotifierItemObject({
    required this.service,
    required this.iconName,
    required this.iconThemePath,
  }) : super(DBusObjectPath('/StatusNotifierItem'));

  final TrayService service;
  final String iconName;
  final String iconThemePath;

  /// False on purpose: true makes left-click open the menu (KDE honors it),
  /// which is exactly the behavior this implementation exists to avoid.
  bool get itemIsMenu => false;

  /// Left-click on the icon.
  Future<void> activate(int x, int y) => service.handleIconClick();

  Map<String, DBusValue> get _properties => {
        'Category': const DBusString('ApplicationStatus'),
        'Id': const DBusString('tangent'),
        'Title': const DBusString('Tangent'),
        'Status': const DBusString('Active'),
        'IconName': DBusString(iconName),
        'IconThemePath': DBusString(iconThemePath),
        'Menu': DBusObjectPath('/MenuBar'),
        'ItemIsMenu': DBusBoolean(itemIsMenu),
        'WindowId': const DBusInt32(0),
      };

  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(
          'org.kde.StatusNotifierItem',
          methods: [
            DBusIntrospectMethod(
              'Activate',
              args: [
                DBusIntrospectArgument(
                  DBusSignature('i'),
                  DBusArgumentDirection.in_,
                  name: 'x',
                ),
                DBusIntrospectArgument(
                  DBusSignature('i'),
                  DBusArgumentDirection.in_,
                  name: 'y',
                ),
              ],
            ),
            DBusIntrospectMethod(
              'ContextMenu',
              args: [
                DBusIntrospectArgument(
                  DBusSignature('i'),
                  DBusArgumentDirection.in_,
                  name: 'x',
                ),
                DBusIntrospectArgument(
                  DBusSignature('i'),
                  DBusArgumentDirection.in_,
                  name: 'y',
                ),
              ],
            ),
          ],
          properties: [
            DBusIntrospectProperty(
              'Category',
              DBusSignature('s'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'Id',
              DBusSignature('s'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'Title',
              DBusSignature('s'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'Status',
              DBusSignature('s'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'IconName',
              DBusSignature('s'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'IconThemePath',
              DBusSignature('s'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'Menu',
              DBusSignature('o'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'ItemIsMenu',
              DBusSignature('b'),
              access: DBusPropertyAccess.read,
            ),
            DBusIntrospectProperty(
              'WindowId',
              DBusSignature('i'),
              access: DBusPropertyAccess.read,
            ),
          ],
        ),
      ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.kde.StatusNotifierItem') {
      switch (methodCall.name) {
        case 'Activate':
          await activate(0, 0);
          return DBusMethodSuccessResponse();
        case 'ContextMenu':
          // The host renders the dbusmenu itself on right-click; nothing
          // to do — but the method must exist and succeed.
          return DBusMethodSuccessResponse();
        case 'SecondaryActivate':
        case 'Scroll':
          return DBusMethodSuccessResponse();
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _properties[name];
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(_properties);
}

/// The /MenuBar object: com.canonical.dbusmenu with the three fixed items.
class DbusMenuObject extends DBusObject {
  DbusMenuObject({required this.service}) : super(DBusObjectPath('/MenuBar'));

  final TrayService service;

  /// Menu ids are 1-based in the order of [TrayService.menuItems]; 0 is
  /// the dbusmenu root.
  static const Map<int, String> _idToKey = {
    1: TrayService.openAppKey,
    2: TrayService.startRecordingKey,
    3: TrayService.exitKey,
  };

  /// The (id, properties, children) layout struct for GetLayout.
  DBusStruct buildLayout() {
    final items = <DBusValue>[];
    var id = 1;
    for (final item in TrayService.menuItems) {
      items.add(
        DBusVariant(
          DBusStruct([
            DBusInt32(id),
            DBusDict(DBusSignature('s'), DBusSignature('v'), {
              const DBusString('label'): DBusVariant(DBusString(item.label)),
              const DBusString('enabled'): const DBusVariant(DBusBoolean(true)),
              const DBusString('visible'): const DBusVariant(DBusBoolean(true)),
            }),
            DBusArray(DBusSignature('v'), const []),
          ]),
        ),
      );
      id++;
    }
    return DBusStruct([
      const DBusInt32(0),
      DBusDict(DBusSignature('s'), DBusSignature('v'), {
        const DBusString('children-display'):
            const DBusVariant(DBusString('submenu')),
      }),
      DBusArray(DBusSignature('v'), items),
    ]);
  }

  /// One menu event from the host. Only 'clicked' acts; unknown ids are
  /// ignored so a stale menu can never crash the app.
  Future<void> handleEvent(int id, String eventId) async {
    if (eventId != 'clicked') return;
    final key = _idToKey[id];
    if (key != null) await service.handleMenuClick(key);
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(
          'com.canonical.dbusmenu',
          methods: [
            DBusIntrospectMethod('GetLayout'),
            DBusIntrospectMethod('Event'),
            DBusIntrospectMethod('AboutToShow'),
            DBusIntrospectMethod('GetGroupProperties'),
          ],
        ),
      ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != 'com.canonical.dbusmenu') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    switch (methodCall.name) {
      case 'GetLayout':
        return DBusMethodSuccessResponse(
          [const DBusUint32(1), buildLayout()],
        );
      case 'Event':
        final id = (methodCall.values[0] as DBusInt32).value;
        final eventId = (methodCall.values[1] as DBusString).value;
        await handleEvent(id, eventId);
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        return DBusMethodSuccessResponse([DBusArray.int32(const [])]);
      case 'AboutToShow':
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return DBusMethodSuccessResponse(
          [DBusArray.int32(const []), DBusArray.int32(const [])],
        );
      case 'GetGroupProperties':
        return DBusMethodSuccessResponse(
          [DBusArray(DBusSignature('(ia{sv})'), const [])],
        );
      case 'GetProperty':
        return DBusMethodSuccessResponse([const DBusVariant(DBusString(''))]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    return switch (name) {
      'Version' => DBusGetPropertyResponse(const DBusUint32(3)),
      'Status' => DBusGetPropertyResponse(const DBusString('normal')),
      'TextDirection' => DBusGetPropertyResponse(const DBusString('ltr')),
      'IconThemePath' => DBusGetPropertyResponse(DBusArray.string(const [])),
      _ => DBusMethodErrorResponse.unknownProperty(),
    };
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        'Version': const DBusUint32(3),
        'Status': const DBusString('normal'),
        'TextDirection': const DBusString('ltr'),
      });
}

/// Owns the D-Bus connection: exports both objects and registers with the
/// StatusNotifierWatcher.
class SniTray {
  SniTray({required this.service});

  final TrayService service;
  DBusClient? _client;

  /// Exports the item and menu, then registers with the watcher.
  ///
  /// [iconDir] must contain hicolor/48x48/apps/tangent.png — KDE resolves
  /// IconName against IconThemePath as a freedesktop icon dir.
  Future<void> install({required String iconDir}) async {
    final client = DBusClient.session();
    _client = client;
    await client.registerObject(
      StatusNotifierItemObject(
        service: service,
        iconName: 'tangent',
        iconThemePath: iconDir,
      ),
    );
    await client.registerObject(DbusMenuObject(service: service));
    await client.callMethod(
      destination: 'org.kde.StatusNotifierWatcher',
      path: DBusObjectPath('/StatusNotifierWatcher'),
      interface: 'org.kde.StatusNotifierWatcher',
      name: 'RegisterStatusNotifierItem',
      values: [DBusString(client.uniqueName)],
      replySignature: DBusSignature(''),
    );
  }

  Future<void> dispose() async {
    await _client?.close();
    _client = null;
  }
}

/// Writes the tray icon asset into a freedesktop-shaped icon dir the SNI
/// host can resolve, and returns that dir.
Future<String> materializeTrayIcon(List<int> pngBytes) async {
  final base = Directory(
    '${Directory.systemTemp.path}/tangent-tray-$pid',
  );
  final iconFile = File('${base.path}/hicolor/48x48/apps/tangent.png');
  await iconFile.create(recursive: true);
  await iconFile.writeAsBytes(pngBytes, flush: true);
  return base.path;
}

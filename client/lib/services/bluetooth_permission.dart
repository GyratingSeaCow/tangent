// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The BLUETOOTH_CONNECT gate for automatic headset capture.
//
// Android 12+ silently refuses SCO bring-up without this runtime
// permission — no error, no dialog, capture just stays on the built-in
// mic (the T5 mystery, solved 2026-09-23: the manifest declared the
// permission but nothing ever requested it).

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Answers "may we route Bluetooth capture?", optionally asking the user.
///
/// [interactive] true (a record tap) may show the system dialog once;
/// false (app foreground / warmRoute) only reads the current state, so a
/// permission popup can never appear out of nowhere.
Future<bool> bluetoothConnectPermission({required bool interactive}) async {
  // Only Android gates SCO behind a runtime permission. Desktop records
  // through the system default and never reaches this path in anger.
  if (!Platform.isAndroid) return false;
  final status = await Permission.bluetoothConnect.status;
  if (status.isGranted) return true;
  if (!interactive) return false;
  // permanentlyDenied means the dialog cannot appear; requesting anyway is
  // a silent no-op reply, so the distinction needs no special-casing.
  final requested = await Permission.bluetoothConnect.request();
  return requested.isGranted;
}

// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

/// The base URL an UNPAIRED client points at, before any server is saved.
///
/// Platform-aware because 10.0.2.2 is the Android emulator's alias for the
/// dev machine's loopback and means nothing anywhere else: a desktop that
/// has never paired used to point every request at it and time out (the
/// v1.7.0 E2E arc's deferred minor). On desktop the honest default is the
/// machine's own loopback on the documented docker-compose port (8765) —
/// right for the common self-hosted-on-this-box case, and visibly wrong
/// (connection refused, immediately) instead of silently black-holed for
/// everyone else.
///
/// [isAndroidOverride] exists for tests; production callers omit it.
String defaultServerBaseUrl({bool? isAndroidOverride}) {
  final bool isAndroid = isAndroidOverride ?? Platform.isAndroid;
  if (isAndroid) return 'http://10.0.2.2:8000';
  return 'http://localhost:8765';
}

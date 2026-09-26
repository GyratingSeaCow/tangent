// SPDX-License-Identifier: AGPL-3.0-or-later
/// Temp directories that the storage backend will accept as roots.
///
/// `FilesystemStorageBackend` refuses a root whose path differs from its
/// symlink-resolved path ("Linked root ancestry is not supported"). On
/// GitHub's windows-latest runners `%TEMP%` (`D:\a\_temp`) sits behind a
/// junction, so a raw `Directory.systemTemp.createTempSync(...)` root
/// trips that guard and every fixture-backed test times out. Resolving
/// once here keeps every test honest on every host.
library;

import 'dart:io';

/// `Directory.systemTemp` with links resolved. Identical to systemTemp on
/// hosts where the temp dir is a real directory.
Directory resolvedSystemTemp() =>
    Directory(Directory.systemTemp.resolveSymbolicLinksSync());

/// A fresh temp directory under [resolvedSystemTemp].
Directory createResolvedTempSync(String prefix) =>
    resolvedSystemTemp().createTempSync(prefix);

/// Async twin of [createResolvedTempSync].
Future<Directory> createResolvedTemp(String prefix) async {
  final base = Directory(await Directory.systemTemp.resolveSymbolicLinks());
  return base.createTemp(prefix);
}

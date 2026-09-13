// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';

/// Helper for Android storage permissions that affect where recordings
/// are saved.
///
/// Recordings must live in a directory that SURVIVES app uninstall — that's
/// the whole point. The natural location is the public "Documents" folder
/// (`/sdcard/Documents/Tangent/`), which means we need broad storage access:
///
/// - Android 10 and below: WRITE_EXTERNAL_STORAGE is granted at install time.
/// - Android 11+ (API 30+): WRITE_EXTERNAL_STORAGE has no effect. The app
///   must hold MANAGE_EXTERNAL_STORAGE, which the user grants from the
///   "All files access" screen in Settings. This is a special flow — we
///   open the Settings activity for the user with [requestManageAllFiles].
class StoragePermission {
  /// Channel name. The Android side doesn't need a handler for the methods
  /// we call from Dart, but we declare the channel so `getExternalStorageDirectory`
  /// from `path_provider` works.
  static const MethodChannel _channel = MethodChannel('dev.tangent.tangent/storage');

  /// Returns true if we can write to the public Documents folder.
  ///
  /// On Android 10-, this is essentially always true after install.
  /// On Android 11+, this checks for MANAGE_EXTERNAL_STORAGE.
  static Future<bool> hasManageAllFiles() async {
    if (!Platform.isAndroid) return true;
    try {
      final granted = await _channel.invokeMethod<bool>('hasManageAllFiles');
      return granted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // No native handler — fall back to checking via environment.
      // Android 13+ exposes this via Environment.isExternalStorageManager,
      // but we don't have access from Dart. Best-effort: try writing.
      return _probeWrite();
    }
  }

  /// Open the system "All files access" settings screen so the user can
  /// grant MANAGE_EXTERNAL_STORAGE. On Android 10-, this is a no-op.
  static Future<void> requestManageAllFiles() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openManageAllFilesSettings');
    } on PlatformException {
      // Fallback: do nothing; the user can grant manually.
    } on MissingPluginException {
      // No native handler; nothing to do.
    }
  }

  /// Best-effort write probe: try creating a temp file in the public
  /// Documents folder. If it works, we have permission.
  static Future<bool> _probeWrite() async {
    try {
      final dir = await _externalDocumentsDir();
      final testFile = File('${dir.path}/.tangent_permission_probe');
      await testFile.writeAsString('ok');
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the public Documents/Tangent directory. Creates it if missing.
  ///
  /// Resolves to:
  /// - Android: `/sdcard/Documents/Tangent/` (survives uninstall)
  /// - Other platforms: falls back to the app's documents directory.
  static Future<Directory> documentsDir() async {
    if (!Platform.isAndroid) {
      return _fallbackDir();
    }
    try {
      final external = await _externalDocumentsDir();
      final tangent = Directory('${external.path}/Tangent');
      if (!await tangent.exists()) {
        await tangent.create(recursive: true);
      }
      return tangent;
    } catch (_) {
      return _fallbackDir();
    }
  }

  static Future<Directory> _externalDocumentsDir() async {
    // path_provider's getExternalStorageDirectory() returns /sdcard/Android/data/<pkg>/files
    // which is APP-SPECIFIC (wiped on uninstall). For PUBLIC Documents, we
    // need a different approach.
    //
    // Trick: the directory `/sdcard/Documents/` is the public Documents folder.
    // We construct it directly. This works on Android 10- with WRITE_EXTERNAL_STORAGE
    // and on Android 11+ with MANAGE_EXTERNAL_STORAGE.
    final external = await _channel.invokeMethod<String>('getPublicDocumentsPath');
    if (external == null) {
      throw const StoragePermissionException('Could not resolve public Documents path');
    }
    return Directory(external);
  }

  static Future<Directory> _fallbackDir() async {
    // Last-resort fallback. path_provider without a public-storage permission.
    // This will be wiped on uninstall but at least lets the app function.
    final dir = Directory.systemTemp;
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

class StoragePermissionException implements Exception {
  final String message;
  const StoragePermissionException(this.message);
  @override
  String toString() => 'StoragePermissionException: $message';
}

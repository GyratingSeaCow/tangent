// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:path/path.dart' as p;

/// Startup directory hints only. Recording reads, publications, enumeration and
/// deletion require captured identities through the bound storage services.
/// The filesystem legacy directory is an input to one-time catalog bootstrap,
/// never a destination inferred by a caller from a recording ID.
class AudioStorage {
  AudioStorage._(this.stagingDir, this._filesystemLegacyDirectory);

  final Directory stagingDir;
  final Directory? _filesystemLegacyDirectory;

  String get audioDirPath =>
      _filesystemLegacyDirectory?.path ??
      (throw StateError('Android legacy storage is resolved by the backend'));

  static Future<AudioStorage> resolve({
    required Directory durableDirectory,
    required Directory stagingDirectory,
  }) async {
    await stagingDirectory.create(recursive: true);
    if (Platform.isAndroid) return AudioStorage._(stagingDirectory, null);
    final legacy = Directory(p.join(durableDirectory.path, 'Tangent'));
    await legacy.create(recursive: true);
    return AudioStorage._(stagingDirectory, legacy);
  }
}

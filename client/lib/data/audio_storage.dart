// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:path/path.dart' as p;

import 'storage_permission.dart';

/// Manages audio file storage in the public Documents/Tangent/ folder.
///
/// Why this directory: the user wants recordings to SURVIVE app uninstall,
/// and the only way to do that on Android is to put files in shared public
/// storage (Documents/). Files in `/data/data/<pkg>/` or `/sdcard/Android/data/<pkg>/`
/// are wiped when the user removes the app.
class AudioStorage {
  static const _tangentSubdir = 'Tangent';
  static const _audioExt = '.opus';
  static const _metaExt = '.meta.json';

  final Directory _audioDir;

  AudioStorage._(this._audioDir);

  /// Test-only constructor. Tests pass a temp dir.
  factory AudioStorage.test(Directory baseDir) {
    final dir = Directory(p.join(baseDir.path, _tangentSubdir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return AudioStorage._(dir);
  }

  /// Production constructor. Resolves the public Documents/Tangent/ folder.
  static Future<AudioStorage> resolve() async {
    final dir = await StoragePermission.documentsDir();
    return AudioStorage._(dir);
  }

  /// Backwards-compatible constructor used by main(). Internally delegates
  /// to [resolve]. The [fallback] directory is used if public-storage access
  /// isn't available (e.g. emulator without storage).
  static Future<AudioStorage> fromDirectoryFallback(Directory fallback) async {
    try {
      return await resolve();
    } catch (_) {
      final dir = Directory(p.join(fallback.path, _tangentSubdir));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return AudioStorage._(dir);
    }
  }

  Directory get audioDir => _audioDir;
  String get audioDirPath => _audioDir.path;

  File pathFor(String id) => File(p.join(_audioDir.path, '$id$_audioExt'));

  File metaPathFor(String id) => File(p.join(_audioDir.path, '$id$_metaExt'));

  Future<int> getSize(String id) async {
    final f = pathFor(id);
    if (!await f.exists()) return 0;
    return await f.length();
  }

  Future<void> deleteFile(String id) async {
    final f = pathFor(id);
    if (await f.exists()) await f.delete();
    final meta = metaPathFor(id);
    if (await meta.exists()) await meta.delete();
  }

  /// Lists all .opus audio files in the storage directory.
  /// Returns pairs of (id, file) so callers can import them.
  Future<List<ImportedAudio>> listAll() async {
    if (!await _audioDir.exists()) return [];
    final entities = await _audioDir.list().toList();
    final result = <ImportedAudio>[];
    for (final e in entities) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith(_audioExt)) continue;
      final id = name.substring(0, name.length - _audioExt.length);
      final size = await e.length();
      final modified = await e.lastModified();
      result.add(ImportedAudio(
        id: id,
        file: e,
        sizeBytes: size,
        modifiedAt: modified,
      ));
    }
    return result;
  }
}

class ImportedAudio {
  final String id;
  final File file;
  final int sizeBytes;
  final DateTime modifiedAt;

  const ImportedAudio({
    required this.id,
    required this.file,
    required this.sizeBytes,
    required this.modifiedAt,
  });
}

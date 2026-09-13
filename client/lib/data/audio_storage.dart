// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:path/path.dart' as p;

class AudioStorage {
  static const _audioDirName = 'audio';
  static const _audioExt = '.opus';

  final Directory _audioDir;

  AudioStorage._(this._audioDir);

  /// Construct from an explicit base directory (used in tests).
  factory AudioStorage.test(Directory baseDir) {
    final dir = Directory(p.join(baseDir.path, _audioDirName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return AudioStorage._(dir);
  }

  /// Async-resolve the audio directory under the app's documents folder.
  /// Use this in production code at startup.
  static Future<AudioStorage> resolve() async {
    // Avoid importing path_provider here to keep this class test-friendly;
    // callers pass in the resolved directory.
    throw UnimplementedError(
      'Use AudioStorage.fromDirectory() in production; '
      'production wiring belongs in the app entry.',
    );
  }

  /// Construct from a pre-resolved app documents directory.
  factory AudioStorage.fromDirectory(Directory docsDir) {
    final dir = Directory(p.join(docsDir.path, _audioDirName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return AudioStorage._(dir);
  }

  Directory get audioDir => _audioDir;

  File pathFor(String id) => File(p.join(_audioDir.path, '$id$_audioExt'));

  Future<int> getSize(String id) async {
    final f = pathFor(id);
    if (!await f.exists()) return 0;
    return await f.length();
  }

  Future<void> deleteFile(String id) async {
    final f = pathFor(id);
    if (await f.exists()) await f.delete();
  }
}
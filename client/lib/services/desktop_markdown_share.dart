// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a desktop Markdown export ended up, and whether a handler opened.
class DesktopMarkdownShareResult {
  const DesktopMarkdownShareResult({required this.path, required this.opened});

  final String path;
  final bool opened;
}

/// Desktop replacement for the mobile share sheet — the Markdown twin of
/// [DesktopPdfShare].
///
/// share_plus's shareXFiles throws UnimplementedError on Linux (no system
/// share sheet exists) and Windows has no equivalent either. The desktop
/// expectation for "export" is: put the file somewhere durable (Documents,
/// not tmp) and show it. This writes the `.md` and opens it with the system
/// handler; both steps are injectable for tests.
class DesktopMarkdownShare {
  DesktopMarkdownShare({
    Future<Directory> Function()? exportDirectory,
    Future<bool> Function(String path)? open,
  })  : _exportDirectory = exportDirectory ?? _defaultExportDirectory,
        _open = open ?? _systemOpen;

  final Future<Directory> Function() _exportDirectory;
  final Future<bool> Function(String path) _open;

  static Future<Directory> _defaultExportDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'Tangent', 'Exports'));
    await directory.create(recursive: true);
    return directory;
  }

  /// xdg-open on Linux; the shell's `start` verb on Windows (there is no
  /// xdg-open there, and `start` is a cmd builtin, not an executable).
  static Future<bool> _systemOpen(String path) async {
    try {
      final result = Platform.isWindows
          ? await Process.run('cmd', ['/c', 'start', '', path])
          : await Process.run('xdg-open', [path]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Writes [markdown] (UTF-8) into the export directory and opens it.
  ///
  /// An existing file with the same name is never clobbered — an export is
  /// a user artifact, and silently overwriting last week's copy would be
  /// data loss. Collisions get ' (2)', ' (3)', ... suffixes.
  ///
  /// A missing handler is NOT a failure: the file exists either way, and
  /// the caller needs its location to tell the user.
  Future<DesktopMarkdownShareResult> shareMarkdown({
    required String markdown,
    required String filename,
  }) async {
    final directory = await _exportDirectory();
    final base = p.basenameWithoutExtension(filename);
    final extension = p.extension(filename);
    File target = File(p.join(directory.path, filename));
    var attempt = 2;
    while (target.existsSync()) {
      target = File(p.join(directory.path, '$base ($attempt)$extension'));
      attempt++;
    }
    await target.writeAsBytes(utf8.encode(markdown), flush: true);
    final opened = await _open(target.path);
    return DesktopMarkdownShareResult(path: target.path, opened: opened);
  }
}

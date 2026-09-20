// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a desktop PDF export ended up, and whether a viewer opened.
class DesktopPdfShareResult {
  const DesktopPdfShareResult({required this.path, required this.opened});

  final String path;
  final bool opened;
}

/// Desktop replacement for the mobile share sheet.
///
/// share_plus's shareXFiles throws UnimplementedError on Linux — there is
/// no system share sheet to open. The desktop expectation for "export"
/// is: put the file somewhere durable (Documents, not tmp) and show it.
/// This writes the PDF and opens it with the system handler (xdg-open);
/// both steps are injectable for tests.
class DesktopPdfShare {
  DesktopPdfShare({
    Future<Directory> Function()? exportDirectory,
    Future<bool> Function(String path)? open,
  })  : _exportDirectory = exportDirectory ?? _defaultExportDirectory,
        _open = open ?? _xdgOpen;

  final Future<Directory> Function() _exportDirectory;
  final Future<bool> Function(String path) _open;

  static Future<Directory> _defaultExportDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'Tangent', 'Exports'));
    await directory.create(recursive: true);
    return directory;
  }

  static Future<bool> _xdgOpen(String path) async {
    try {
      final result = await Process.run('xdg-open', [path]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Writes [bytes] into the export directory and opens the result.
  ///
  /// An existing file with the same name is never clobbered — an export is
  /// a user artifact, and silently overwriting last week's copy would be
  /// data loss. Collisions get ' (2)', ' (3)', ... suffixes.
  ///
  /// A missing viewer is NOT a failure: the file exists either way, and
  /// the caller needs its location to tell the user.
  Future<DesktopPdfShareResult> sharePdf({
    required Uint8List bytes,
    required String filename,
    required String subject,
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
    await target.writeAsBytes(bytes, flush: true);
    final opened = await _open(target.path);
    return DesktopPdfShareResult(path: target.path, opened: opened);
  }
}

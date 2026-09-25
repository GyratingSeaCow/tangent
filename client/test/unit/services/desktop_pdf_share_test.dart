// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/services/desktop_pdf_share.dart';

/// share_plus's shareXFiles is UnimplementedError on Linux: there is no
/// system share sheet to open. The desktop equivalent of "share" is: put
/// the PDF somewhere durable and show it to the user. This service writes
/// the bytes and opens the file with the system handler (xdg-open),
/// injectable so tests don't launch real viewers.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tangent-pdf-share-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('writes the PDF and opens it with the launcher', () async {
    final opened = <String>[];
    final share = DesktopPdfShare(
      exportDirectory: () async => dir,
      open: (path) async {
        opened.add(path);
        return true;
      },
    );

    await share.sharePdf(
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      filename: 'My Notes.pdf',
      subject: 'My Notes',
    );

    final written = File(p.join(dir.path, 'My Notes.pdf'));
    expect(written.existsSync(), isTrue);
    expect(await written.readAsBytes(), [1, 2, 3, 4]);
    expect(opened, [written.path]);
  });

  test('a second export of the same name does not clobber the first', () async {
    final share = DesktopPdfShare(
      exportDirectory: () async => dir,
      open: (_) async => true,
    );
    await share.sharePdf(
      bytes: Uint8List.fromList([1]),
      filename: 'notes.pdf',
      subject: 'notes',
    );
    await share.sharePdf(
      bytes: Uint8List.fromList([2]),
      filename: 'notes.pdf',
      subject: 'notes',
    );

    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(files.length, 2, reason: 'both exports must survive');
    expect(files, containsAll(['notes.pdf', 'notes (2).pdf']));
    expect(
      await File(p.join(dir.path, 'notes.pdf')).readAsBytes(),
      [1],
      reason: 'the original is untouched',
    );
  });

  test('a failed open still reports where the file landed', () async {
    final share = DesktopPdfShare(
      exportDirectory: () async => dir,
      open: (_) async => false,
    );
    final result = await share.sharePdf(
      bytes: Uint8List.fromList([9]),
      filename: 'x.pdf',
      subject: 'x',
    );
    // No viewer installed is not a failed export: the file exists and the
    // caller needs its path to tell the user, not an exception.
    expect(result.opened, isFalse);
    expect(File(result.path).existsSync(), isTrue);
  });
}

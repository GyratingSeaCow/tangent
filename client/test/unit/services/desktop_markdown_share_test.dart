// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/services/desktop_markdown_share.dart';
import '../../support/resolved_temp.dart';

/// Desktop twin of the PDF share (v1.16.0 spec §4): no share sheet exists on
/// Linux/Windows, so "export" means write the .md somewhere durable and open
/// it with the system handler — both injectable so tests launch nothing.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await createResolvedTemp('tangent-md-share-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('writes the Markdown (UTF-8) and opens it with the handler', () async {
    final opened = <String>[];
    final share = DesktopMarkdownShare(
      exportDirectory: () async => dir,
      open: (path) async {
        opened.add(path);
        return true;
      },
    );

    final result = await share.shareMarkdown(
      markdown: '# Sprint — planning\n\n[00:05] Jeff: héllo\n',
      filename: 'Sprint planning-20260926-1200.md',
    );

    final written = File(p.join(dir.path, 'Sprint planning-20260926-1200.md'));
    expect(written.existsSync(), isTrue);
    expect(
      await written.readAsString(),
      '# Sprint — planning\n\n[00:05] Jeff: héllo\n',
    );
    expect(opened, [written.path]);
    expect(result.path, written.path);
    expect(result.opened, isTrue);
  });

  test('a second export of the same name does not clobber the first', () async {
    final share = DesktopMarkdownShare(
      exportDirectory: () async => dir,
      open: (_) async => true,
    );
    await share.shareMarkdown(markdown: 'one', filename: 'notes.md');
    await share.shareMarkdown(markdown: 'two', filename: 'notes.md');

    final files = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(files, containsAll(['notes.md', 'notes (2).md']));
    expect(files.length, 2, reason: 'both exports must survive');
    expect(
      await File(p.join(dir.path, 'notes.md')).readAsString(),
      'one',
      reason: 'the original is untouched',
    );
  });

  test('a failed open still reports where the file landed', () async {
    final share = DesktopMarkdownShare(
      exportDirectory: () async => dir,
      open: (_) async => false,
    );
    final result =
        await share.shareMarkdown(markdown: 'x', filename: 'x.md');
    expect(result.opened, isFalse);
    expect(File(result.path).existsSync(), isTrue);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/services/desktop_markdown_share.dart';
import 'package:tangent/services/markdown_export.dart';

import '../../support/dump_view_fixture.dart';
import '../../support/resolved_temp.dart';

/// Per-recording export (v1.16.0 spec §4): file naming, the offer gate, and
/// the desktop branch driven end-to-end through a fake writer + opener.
void main() {
  group('markdownExportFileName', () {
    test('sanitised title + creation stamp + .md', () {
      final row = viewRow('r1').copyWith(title: 'Q3: plan/review?');
      final name = markdownExportFileName(
        row,
        at: DateTime(2026, 9, 26, 14, 7),
      );
      expect(name, 'Q3_ plan_review_-20260926-1407.md');
    });

    test('a blank title falls back to recording', () {
      final row = viewRow('r1').copyWith(title: '   ');
      expect(
        markdownExportFileName(row, at: DateTime(2026, 1, 2, 3, 4)),
        'recording-20260102-0304.md',
      );
    });
  });

  group('canExportMarkdown', () {
    test('only when there is transcript text', () {
      expect(canExportMarkdown(viewRow('r1')), isFalse);
      expect(
        canExportMarkdown(
          viewRow('r1').copyWith(transcript: const Value<String?>('  \n')),
        ),
        isFalse,
      );
      expect(
        canExportMarkdown(
          viewRow('r1').copyWith(transcript: const Value<String?>('hello')),
        ),
        isTrue,
      );
    });
  });

  group('exportRecordingMarkdown on desktop', () {
    late Directory dir;
    setUp(() async {
      dir = await createResolvedTemp('tangent-md-export-');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('renders with timestamps + summary, writes the file, opens it',
        () async {
      final opened = <String>[];
      final row = viewRow('r1').copyWith(
        title: 'Standup',
        transcript: const Value<String?>('## Speaker 1\nhello there\n'),
        transcriptTimings: const Value<String?>(
          '{"segments":[{"start":5.2,"end":6.0,"speaker":"Speaker 1",'
          '"text":"hello there","words":[]}]}',
        ),
        summary: const Value<String?>('We said hello.'),
      );
      final outcome = await exportRecordingMarkdown(
        row,
        desktop: true,
        desktopShare: DesktopMarkdownShare(
          exportDirectory: () async => dir,
          open: (path) async {
            opened.add(path);
            return true;
          },
        ),
      );

      final expectedName = markdownExportFileName(row);
      final file = File(p.join(dir.path, expectedName));
      expect(file.existsSync(), isTrue, reason: 'written under Documents');
      expect(opened, [file.path]);
      expect(outcome.path, file.path);
      expect(outcome.opened, isTrue);
      expect(outcome.message, 'Exported to ${file.path}');

      final text = await file.readAsString();
      expect(text, contains('## Summary'));
      expect(text, contains('We said hello.'));
      expect(text, contains('[00:05] Speaker 1: hello there'));
      expect(text, contains('timestamps: segments'));
    });

    test('a missing handler is reported, not thrown', () async {
      final row = viewRow('r1').copyWith(
        transcript: const Value<String?>('plain text'),
      );
      final outcome = await exportRecordingMarkdown(
        row,
        desktop: true,
        desktopShare: DesktopMarkdownShare(
          exportDirectory: () async => dir,
          open: (_) async => false,
        ),
      );
      expect(outcome.opened, isFalse);
      expect(outcome.message, contains('(no Markdown handler)'));
      expect(File(outcome.path!).existsSync(), isTrue);
    });
  });
}

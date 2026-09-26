// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Timestamped Markdown export (v1.16.0, spec §5 unit). Rules pinned:
//  * `[mm:ss]` stamps, promoted to `[h:mm:ss]` for the WHOLE document
//    once any segment starts at or past one hour — never mixed
//  * speaker names resolve by pairing `## <heading>` lines with the
//    timings' `Speaker N` labels in first-appearance order; a count
//    mismatch falls back to the raw labels; `[unattributed]` never pairs
//  * `## Summary` only when wanted and real (not blank, not `None`)
//  * no timings → raw body + `timestamps: none`; text notes never stamp
//  * `dumpMarkdown` is a thin wrapper whose output is pinned by a golden

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/services/obsidian_export.dart';
import 'package:tangent/services/transcript_markdown.dart';
import 'package:tangent/services/transcript_timings.dart';

DumpRow row({
  String id = 'dump-1',
  String title = 'Standup',
  DumpMode mode = DumpMode.meeting,
  int durationSeconds = 95,
  String? transcript = 'Buy oat milk and batteries.',
  String? summary,
  String? summaryTemplate,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 23, 14, 30),
      updatedAt: DateTime.utc(2026, 9, 23, 14, 30),
      mode: mode.wireValue,
      durationSeconds: durationSeconds,
      title: title,
      transcript: transcript,
      audioPath: '',
      audioSizeBytes: 0,
      syncStatus: 'local',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 0,
      summary: summary,
      summaryTemplate: summaryTemplate,
    );

TranscriptTimings timings(List<(double, String?, String)> segments) {
  final json = StringBuffer('{"segments":[');
  json.write(
    segments
        .map(
          (s) => '{"start":${s.$1},"end":${s.$1 + 1},'
              '"speaker":${s.$2 == null ? 'null' : '"${s.$2}"'},'
              '"text":"${s.$3}"}',
        )
        .join(','),
  );
  json.write(']}');
  return TranscriptTimings.parse(json.toString())!;
}

const stamped = TranscriptMarkdownOptions(timestamps: true);
const plain = TranscriptMarkdownOptions();

String bodyOf(String md) => md.substring(md.indexOf('## Transcript'));

void main() {
  group('timestamps', () {
    test('one [mm:ss] line per segment; speaker lines carry the name', () {
      final md = transcriptMarkdown(
        dump: row(transcript: '## Speaker 1\n\nHello\n\n## Speaker 2\n\nHi'),
        timings: timings([
          (5.9, 'Speaker 1', 'Hello'),
          (65.2, 'Speaker 2', 'Hi'),
          (70, null, 'Plain line'),
        ]),
        options: stamped,
      );

      expect(
        bodyOf(md),
        '## Transcript\n\n'
        '[00:05] Speaker 1: Hello\n'
        '[01:05] Speaker 2: Hi\n'
        '[01:10] Plain line\n',
      );
      expect(md, contains('timestamps: segments'));
    });

    test('any segment past one hour promotes the WHOLE document to h:mm:ss',
        () {
      final md = transcriptMarkdown(
        dump: row(transcript: null),
        timings: timings([
          (5, null, 'early'),
          (3723.4, null, 'late'),
        ]),
        options: stamped,
      );

      expect(md, contains('[0:00:05] early'));
      expect(md, contains('[1:02:03] late'));
      expect(md, isNot(contains('[00:05]')), reason: 'never mixed widths');
    });

    test('a document with nothing past one hour stays mm:ss', () {
      final md = transcriptMarkdown(
        dump: row(),
        timings: timings([(3599, null, 'almost')]),
        options: stamped,
      );

      expect(md, contains('[59:59] almost'));
    });

    test('blank segments are skipped', () {
      final md = transcriptMarkdown(
        dump: row(),
        timings: timings([
          (1, null, 'kept'),
          (2, null, '   '),
          (3, null, 'also kept'),
        ]),
        options: stamped,
      );

      expect(bodyOf(md), '## Transcript\n\n[00:01] kept\n[00:03] also kept\n');
    });

    test('no timings + timestamps on → raw body and timestamps: none', () {
      final md = transcriptMarkdown(
        dump: row(transcript: 'Raw text here.'),
        timings: null,
        options: stamped,
      );

      expect(md, contains('timestamps: none'));
      expect(bodyOf(md), '## Transcript\n\nRaw text here.\n');
    });

    test('timestamps off → raw body, no timestamps key', () {
      final md = transcriptMarkdown(
        dump: row(transcript: 'Raw text here.'),
        timings: timings([(1, 'Speaker 1', 'Raw text here.')]),
        options: plain,
      );

      expect(md, isNot(contains('timestamps:')));
      expect(bodyOf(md), '## Transcript\n\nRaw text here.\n');
    });

    test('text notes never get timestamps regardless of options', () {
      final md = transcriptMarkdown(
        dump: row(mode: DumpMode.textNote, transcript: 'Just a note.'),
        timings: timings([(1, null, 'Just a note.')]),
        options: stamped,
      );

      expect(md, isNot(contains('timestamps:')));
      expect(md, isNot(contains('duration:')));
      expect(md, isNot(contains('## Transcript')));
      expect(md, isNot(contains('[00:01]')));
      expect(md, endsWith('# Standup\n\nJust a note.\n'));
    });
  });

  group('speaker name resolution', () {
    final two = timings([
      (0, 'Speaker 1', 'Morning'),
      (4, 'Speaker 2', 'Morning to you'),
      (8, 'Speaker 1', 'Ready?'),
    ]);

    test('headings pair with Speaker N by first appearance', () {
      final md = transcriptMarkdown(
        dump: row(
          transcript: '## Jeff\n\nMorning\nReady?\n\n## Dana\n\nMorning to you',
        ),
        timings: two,
        options: stamped,
      );

      expect(md, contains('[00:00] Jeff: Morning'));
      expect(md, contains('[00:04] Dana: Morning to you'));
      expect(md, contains('[00:08] Jeff: Ready?'));
      expect(md, contains('speakers:\n  - Jeff\n  - Dana\n'));
    });

    test('a heading equal to Speaker N maps to itself', () {
      final md = transcriptMarkdown(
        dump: row(transcript: '## Jeff\n\nMorning\n\n## Speaker 2\n\nHi'),
        timings: two,
        options: stamped,
      );

      expect(md, contains('[00:00] Jeff: Morning'));
      expect(md, contains('[00:04] Speaker 2: Morning to you'));
    });

    test('[unattributed] is never paired', () {
      final md = transcriptMarkdown(
        dump: row(
          transcript: '## Jeff\n\nMorning\n\n## Dana\n\nHi\n\n'
              '## [unattributed]\n\nnoise',
        ),
        timings: two,
        options: stamped,
      );

      expect(md, contains('[00:00] Jeff: Morning'));
      expect(md, contains('[00:04] Dana: Morning to you'));
      expect(md, isNot(contains('[unattributed]')));
    });

    test('heading count mismatch falls back to raw labels — never guesses',
        () {
      final md = transcriptMarkdown(
        dump: row(transcript: '## Jeff\n\nMorning\nMorning to you\nReady?'),
        timings: two,
        options: stamped,
      );

      expect(md, contains('[00:00] Speaker 1: Morning'));
      expect(md, contains('[00:04] Speaker 2: Morning to you'));
      expect(md, isNot(contains('Jeff:')));
      expect(md, contains('speakers:\n  - Speaker 1\n  - Speaker 2\n'));
    });

    test('speakers key is omitted when there are none', () {
      final md = transcriptMarkdown(
        dump: row(mode: DumpMode.brainDump, transcript: 'solo'),
        timings: timings([(0, null, 'solo')]),
        options: stamped,
      );

      expect(md, isNot(contains('speakers:')));
    });
  });

  group('summary', () {
    const summary = '## Decisions\n\n- Ship it';

    test('present when wanted and real, with its template in frontmatter',
        () {
      final md = transcriptMarkdown(
        dump: row(summary: summary, summaryTemplate: 'meeting'),
        timings: null,
        options: plain,
      );

      expect(md, contains('summary-template: meeting'));
      expect(
        md,
        contains('# Standup\n\n## Summary\n\n$summary\n\n## Transcript\n\n'),
      );
    });

    test('absent when blank', () {
      final md = transcriptMarkdown(
        dump: row(summary: '   \n', summaryTemplate: 'meeting'),
        timings: null,
        options: plain,
      );

      expect(md, isNot(contains('## Summary')));
      expect(md, isNot(contains('summary-template')));
    });

    test('absent when the literal None (actions-only all-None case)', () {
      final md = transcriptMarkdown(
        dump: row(summary: 'None'),
        timings: null,
        options: plain,
      );

      expect(md, isNot(contains('## Summary')));
    });

    test('absent when includeSummary is false', () {
      final md = transcriptMarkdown(
        dump: row(summary: summary, summaryTemplate: 'meeting'),
        timings: null,
        options: const TranscriptMarkdownOptions(includeSummary: false),
      );

      expect(md, isNot(contains('## Summary')));
      expect(md, isNot(contains('summary-template')));
    });
  });

  group('frontmatter', () {
    test('keys in spec order, none of the optional ones when absent', () {
      final md = transcriptMarkdown(
        dump: row(mode: DumpMode.brainDump, transcript: 'x'),
        timings: null,
        options: plain,
      );

      expect(
        md,
        startsWith(
          '---\n'
          'tangent-id: dump-1\n'
          'title: Standup\n'
          'created: 2026-09-23T14:30:00.000Z\n'
          'type: brain-dump\n'
          'duration: 0:01:35\n'
          'source: tangent\n'
          '---\n',
        ),
      );
    });

    test('a title YAML would misread is quoted', () {
      final md = transcriptMarkdown(
        dump: row(title: 'Plan: phase two'),
        timings: null,
        options: plain,
      );

      expect(md, contains('title: "Plan: phase two"'));
    });

    test('an untranscribed recording says so instead of exporting nothing',
        () {
      final md = transcriptMarkdown(
        dump: row(transcript: null),
        timings: null,
        options: stamped,
      );

      expect(md, contains('*Not transcribed yet.*'));
    });
  });

  group('dumpMarkdown wrapper', () {
    // This golden is the v1.15.0 `dumpMarkdown` output verbatim: with both
    // options off the vault file shape MUST NOT change (no title key, no
    // speakers key, no `## Transcript` heading).
    test('is pinned byte-for-byte to the v1.15.0 shape (timestamps off, no summary)', () {
      final md = dumpMarkdown(
        id: 'dump-1',
        title: 'Groceries idea',
        createdAt: DateTime.utc(2026, 9, 23, 14, 30),
        mode: DumpMode.brainDump,
        durationSeconds: 95,
        transcript: 'Buy oat milk and batteries.',
      );

      expect(
        md,
        '---\n'
        'tangent-id: dump-1\n'
        'created: 2026-09-23T14:30:00.000Z\n'
        'type: brain-dump\n'
        'duration: 0:01:35\n'
        'source: tangent\n'
        '---\n'
        '\n'
        '# Groceries idea\n'
        '\n'
        'Buy oat milk and batteries.\n',
      );
    });

    test('equals transcriptMarkdown with the wrapper options', () {
      final dump = row(
        transcript: '## Jeff\n\nMorning',
        summary: 'ignored by the wrapper',
      );
      expect(
        dumpMarkdown(
          id: dump.id,
          title: dump.title,
          createdAt: dump.createdAt,
          mode: DumpMode.fromWire(dump.mode),
          durationSeconds: dump.durationSeconds,
          transcript: dump.transcript,
        ),
        transcriptMarkdown(
          dump: row(transcript: '## Jeff\n\nMorning'),
          timings: null,
          options: const TranscriptMarkdownOptions(
            timestamps: false,
            includeSummary: false,
          ),
        ),
      );
    });
  });
}

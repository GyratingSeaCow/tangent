// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Rendered transcript block (v1.20.0, spec §B + §Verification).
//  * names from the speaker-name map first, heading pairing second, raw
//    `Speaker N` last — identical to the Markdown export
//  * one paragraph per speaker turn, blank line between, `[mm:ss]` per turn
//  * `[h:mm:ss]` for the whole block once any segment passes an hour
//  * no timings → no stamps, ever
//  * mono transcript → plain stamped paragraphs
//  * every stamp offset points at `[` and covers through `]`

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/models/speaker_names.dart';
import 'package:tangent/services/transcript_page_text.dart';
import 'package:tangent/services/transcript_timings.dart';

DumpRow row({
  String id = 'dump-1',
  String title = 'Standup',
  String? transcript = '## Speaker 1\n\nHello\n\n## Speaker 2\n\nHi',
  String? speakerNames,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 27, 9),
      updatedAt: DateTime.utc(2026, 9, 27, 9),
      mode: DumpMode.meeting.wireValue,
      durationSeconds: 95,
      title: title,
      transcript: transcript,
      audioPath: '',
      audioSizeBytes: 0,
      syncStatus: 'local',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 0,
      speakerNames: speakerNames,
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

const SpeakerNames noNames = SpeakerNames.empty();

/// The two-speaker fixture every naming test renders.
final TranscriptTimings twoSpeakers = timings([
  (0, 'Speaker 1', 'Morning'),
  (2.4, 'Speaker 1', 'Ready?'),
  (5.9, 'Speaker 2', 'Morning to you'),
]);

void main() {
  group('speaker names', () {
    test('come from the name map first', () {
      final page = transcriptPageText(
        dump: row(
          transcript: '## Speaker 1\n\nMorning\nReady?\n\n## Speaker 2\n\n'
              'Morning to you',
          speakerNames: '{"Speaker 1":"Jeff","Speaker 2":"Dana"}',
        ),
        timings: twoSpeakers,
        speakerNames: SpeakerNames({'Speaker 1': 'Jeff', 'Speaker 2': 'Dana'}),
      );
      expect(
        page.text,
        '[00:00] Jeff: Morning Ready?\n\n[00:05] Dana: Morning to you',
      );
      expect(page.text, isNot(contains('Speaker 1')));
    });

    test('the map wins over headings that disagree with it', () {
      final page = transcriptPageText(
        dump:
            row(transcript: '## Jeff\n\nMorning\n\n## Dana\n\nMorning to you'),
        timings: twoSpeakers,
        speakerNames: SpeakerNames({'Speaker 2': 'Dana'}),
      );
      // A map with entries resolves EVERY label through it: unmapped
      // labels stay raw, the headings are never consulted.
      expect(page.text, startsWith('[00:00] Speaker 1: Morning'));
      expect(page.text, contains('[00:05] Dana: Morning to you'));
    });

    test('fall back to heading pairing when there is no map', () {
      final page = transcriptPageText(
        dump: row(
          transcript: '## Jeff\n\nMorning\nReady?\n\n## Dana\n\nMorning to you',
        ),
        timings: twoSpeakers,
        speakerNames: noNames,
      );
      expect(
        page.text,
        '[00:00] Jeff: Morning Ready?\n\n[00:05] Dana: Morning to you',
      );
    });

    test('fall back to raw labels when headings cannot be paired', () {
      final page = transcriptPageText(
        dump: row(transcript: '## Jeff\n\nMorning\nMorning to you\nReady?'),
        timings: twoSpeakers,
        speakerNames: noNames,
      );
      expect(page.text, contains('[00:00] Speaker 1: Morning Ready?'));
      expect(page.text, contains('[00:05] Speaker 2: Morning to you'));
    });
  });

  group('turns and stamps', () {
    test('one paragraph per speaker turn, blank line between, no headings', () {
      final page = transcriptPageText(
        dump: row(),
        timings: timings([
          (0, 'Speaker 1', 'One.'),
          (1, 'Speaker 1', 'Two.'),
          (3, 'Speaker 2', 'Three.'),
          (4, 'Speaker 1', 'Four.'),
        ]),
        speakerNames: SpeakerNames({'Speaker 1': 'Jeff'}),
      );
      expect(
        page.text,
        '[00:00] Jeff: One. Two.\n\n'
        '[00:03] Speaker 2: Three.\n\n'
        '[00:04] Jeff: Four.',
      );
      expect(page.text, isNot(contains('##')));
      expect(page.text, isNot(startsWith('---')));
      expect(page.stamps.map((s) => s.seconds), [0.0, 3.0, 4.0]);
      expect(page.stamps.map((s) => s.dumpId), everyElement('dump-1'));
    });

    test('every stamp offset points exactly at [ and covers through ]', () {
      final page = transcriptPageText(
        dump: row(),
        timings: timings([
          (0, 'Speaker 1', 'One.'),
          (65.2, 'Speaker 2', 'Two.'),
          (130, 'Speaker 1', 'Three.'),
        ]),
        speakerNames: SpeakerNames({'Speaker 1': 'Jeff'}),
      );
      expect(page.stamps, hasLength(3));
      final expected = <String>['[00:00]', '[01:05]', '[02:10]'];
      for (var i = 0; i < page.stamps.length; i++) {
        final stamp = page.stamps[i];
        final slice = page.text.substring(
          stamp.offset,
          stamp.offset + stamp.length,
        );
        expect(slice, expected[i], reason: 'stamp $i slice');
        expect(page.text[stamp.offset], '[', reason: 'stamp $i starts at [');
        expect(
          page.text[stamp.offset + stamp.length - 1],
          ']',
          reason: 'stamp $i ends at ]',
        );
        if (stamp.offset > 0) {
          expect(
            page.text[stamp.offset - 1],
            '\n',
            reason: 'stamp $i opens its paragraph',
          );
        }
      }
      expect(page.stamps.map((s) => s.seconds), [0.0, 65.2, 130.0]);
    });

    test('whole block promotes to h:mm:ss once any segment passes an hour', () {
      final page = transcriptPageText(
        dump: row(),
        timings: timings([
          (5, 'Speaker 1', 'Early'),
          (3600, 'Speaker 2', 'Late'),
        ]),
        speakerNames: noNames,
      );
      expect(
        page.text,
        '[0:00:05] Speaker 1: Early\n\n[1:00:00] Speaker 2: Late',
      );
      expect(page.stamps.map((s) => s.length), everyElement(9));
      expect(
        page.text.substring(page.stamps[1].offset, page.stamps[1].offset + 9),
        '[1:00:00]',
      );
    });

    test('mono transcript: plain paragraphs stamped per segment', () {
      final page = transcriptPageText(
        dump: row(transcript: 'Buy oat milk. And batteries.'),
        timings: timings([
          (1, null, 'Buy oat milk.'),
          (3, null, 'And batteries.'),
        ]),
        speakerNames: noNames,
      );
      expect(page.text, '[00:01] Buy oat milk.\n\n[00:03] And batteries.');
      expect(page.stamps, hasLength(2));
      expect(page.text[page.stamps[1].offset], '[');
      expect(page.text, isNot(contains(':  ')));
    });

    test('blank segments are skipped', () {
      final page = transcriptPageText(
        dump: row(),
        timings: timings([
          (0, 'Speaker 1', '   '),
          (2, 'Speaker 1', 'kept'),
        ]),
        speakerNames: noNames,
      );
      expect(page.text, '[00:02] Speaker 1: kept');
      expect(page.stamps.single.seconds, 2);
    });
  });

  group('no timings', () {
    test('turns render without stamps and the stamp list is empty', () {
      final page = transcriptPageText(
        dump: row(
          transcript: '## Speaker 1\n\nMorning\nReady?\n\n## Speaker 2\n\n'
              'Morning to you',
        ),
        timings: null,
        speakerNames: SpeakerNames({'Speaker 1': 'Jeff'}),
      );
      expect(page.text, 'Jeff: Morning\nReady?\n\nSpeaker 2: Morning to you');
      expect(page.stamps, isEmpty);
      expect(page.text, isNot(contains('[')), reason: 'never fake a time');
    });

    test('headingless text passes through untouched, no stamps', () {
      final page = transcriptPageText(
        dump: row(transcript: '  Raw text here.\n'),
        timings: null,
        speakerNames: noNames,
      );
      expect(page.text, 'Raw text here.');
      expect(page.stamps, isEmpty);
    });

    test('a blank transcript renders empty', () {
      final page = transcriptPageText(
        dump: row(transcript: '   '),
        timings: null,
        speakerNames: noNames,
      );
      expect(page.text, '');
      expect(page.isEmpty, isTrue);
      expect(page.stamps, isEmpty);
    });
  });

  group('TextStamp', () {
    test('round-trips through short-key JSON and is value-equal', () {
      const stamp = TextStamp(offset: 7, length: 7, seconds: 65.2, dumpId: 'd');
      expect(stamp.toJson(), {'o': 7, 'l': 7, 's': 65.2, 'd': 'd'});
      expect(TextStamp.fromJson(stamp.toJson()), stamp);
      expect(TextStamp.fromJson(stamp.toJson()).hashCode, stamp.hashCode);
      expect(
        TextStamp.tryFromJson({'o': 7, 'l': 7, 's': 65, 'd': 'd'}),
        const TextStamp(offset: 7, length: 7, seconds: 65, dumpId: 'd'),
      );
    });

    test('rejects garbage', () {
      expect(TextStamp.tryFromJson(null), isNull);
      expect(TextStamp.tryFromJson('x'), isNull);
      expect(
        TextStamp.tryFromJson({'o': '7', 'l': 7, 's': 1, 'd': 'd'}),
        isNull,
      );
      expect(TextStamp.tryFromJson({'o': 7, 'l': 0, 's': 1, 'd': 'd'}), isNull);
      expect(
        TextStamp.tryFromJson({'o': -1, 'l': 7, 's': 1, 'd': 'd'}),
        isNull,
      );
      expect(TextStamp.tryFromJson({'o': 7, 'l': 7, 's': 1}), isNull);
      expect(() => TextStamp.fromJson({}), throwsFormatException);
    });
  });
}

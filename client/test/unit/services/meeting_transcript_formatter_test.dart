// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/meeting_transcript_formatter.dart';

void main() {
  group('parseTranscriptSegments', () {
    test('returns an empty list for absent or non-list payloads', () {
      expect(parseTranscriptSegments(null), isEmpty);
      expect(parseTranscriptSegments('not a list'), isEmpty);
      expect(parseTranscriptSegments(const <Object?>[]), isEmpty);
      expect(parseTranscriptSegments(const {'start': 0}), isEmpty);
    });

    test('reads start, end, speaker and text from well formed maps', () {
      final segments = parseTranscriptSegments(const [
        {'start': 0.0, 'end': 4.25, 'speaker': 'Speaker 1', 'text': 'Hello.'},
      ]);

      expect(segments, hasLength(1));
      expect(segments.single.start, 0.0);
      expect(segments.single.end, 4.25);
      expect(segments.single.speaker, 'Speaker 1');
      expect(segments.single.text, 'Hello.');
    });

    test('accepts integer and string numerics for start and end', () {
      final segments = parseTranscriptSegments(const [
        {'start': 12, 'end': '19.5', 'speaker': 'A', 'text': 'x'},
      ]);

      expect(segments.single.start, 12.0);
      expect(segments.single.end, 19.5);
    });

    test('defaults a missing or unparsable start to zero', () {
      final segments = parseTranscriptSegments(const [
        {'speaker': 'A', 'text': 'no start'},
        {'start': 'nonsense', 'speaker': 'A', 'text': 'bad start'},
      ]);

      expect(segments.map((s) => s.start), [0.0, 0.0]);
    });

    test('clamps negative start values to zero', () {
      final segments = parseTranscriptSegments(const [
        {'start': -3.5, 'text': 'before zero'},
      ]);

      expect(segments.single.start, 0.0);
    });

    test('drops entries that are not maps or carry no text', () {
      final segments = parseTranscriptSegments(const [
        'garbage',
        42,
        {'start': 1.0, 'text': '   '},
        {'start': 2.0},
        {'start': 3.0, 'text': 'kept'},
      ]);

      expect(segments, hasLength(1));
      expect(segments.single.text, 'kept');
    });

    test('normalises a blank or non-string speaker to null', () {
      final segments = parseTranscriptSegments(const [
        {'start': 0.0, 'speaker': '   ', 'text': 'a'},
        {'start': 1.0, 'speaker': null, 'text': 'b'},
        {'start': 2.0, 'speaker': 7, 'text': 'c'},
      ]);

      expect(segments.map((s) => s.speaker), [null, null, null]);
    });

    test('trims surrounding whitespace from text and speaker', () {
      final segments = parseTranscriptSegments(const [
        {'start': 0.0, 'speaker': '  Speaker 2  ', 'text': '  padded  '},
      ]);

      expect(segments.single.speaker, 'Speaker 2');
      expect(segments.single.text, 'padded');
    });
  });

  group('formatMeetingTranscript (speaker digest)', () {
    test('returns null when there are no segments', () {
      expect(formatMeetingTranscript(const []), isNull);
    });

    test('merges all null-speaker segments within one minute into a single '
        'paragraph with one leading marker (zero-speaker fallback)', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, text: 'First chunk.'),
        TranscriptSegment(start: 6, text: 'Second chunk.'),
        TranscriptSegment(start: 22, text: 'Third chunk.'),
      ]);

      expect(formatted, '[00:00] First chunk. Second chunk. Third chunk.');
    });

    test('starts a new paragraph when a minute boundary passes '
        '(zero-speaker fallback)', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, text: 'First chunk.'),
        TranscriptSegment(start: 30, text: 'Same minute.'),
        TranscriptSegment(start: 61, text: 'Second chunk.'),
      ]);

      expect(
        formatted,
        '[00:00] First chunk. Same minute.\n'
        '\n'
        '[01:01] Second chunk.',
      );
    });

    test('marker carries the start of the paragraph, not the boundary '
        '(zero-speaker fallback)', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 59, text: 'one'),
        TranscriptSegment(start: 125.7, text: 'two'),
      ]);

      expect(formatted, '[00:59] one\n\n[02:05] two');
    });

    test('renders one section per speaker with everything they said', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, speaker: 'Speaker 1', text: 'Hello there.'),
        TranscriptSegment(
          start: 247.5,
          speaker: 'Speaker 2',
          text: 'Follow up later.',
        ),
      ]);

      expect(
        formatted,
        '## Speaker 1\n'
        '\n'
        'Hello there.\n'
        '\n'
        '## Speaker 2\n'
        '\n'
        'Follow up later.',
      );
    });

    test("collects a speaker's segments one per line", () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 5, speaker: 'Speaker 1', text: 'One.'),
        TranscriptSegment(start: 40, speaker: 'Speaker 1', text: 'Two.'),
        TranscriptSegment(start: 80, speaker: 'Speaker 1', text: 'Three.'),
      ]);

      expect(formatted, '## Speaker 1\n\nOne.\nTwo.\nThree.');
    });

    test('interleaved speakers stay chronological within their sections', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, speaker: 'Ada', text: 'a1'),
        TranscriptSegment(start: 10, speaker: 'Bob', text: 'b1'),
        TranscriptSegment(start: 20, speaker: 'Ada', text: 'a2'),
      ]);

      expect(formatted, '## Speaker 1\n\na1\na2\n\n## Speaker 2\n\nb1');
    });

    test('renumbers speakers by first appearance in the recording', () {
      final formatted = formatMeetingTranscript(const [
        // Payload order deliberately not chronological.
        TranscriptSegment(
          start: 12,
          speaker: 'SPEAKER_07',
          text: 'Second voice.',
        ),
        TranscriptSegment(
          start: 0,
          speaker: 'SPEAKER_03',
          text: 'First voice.',
        ),
        TranscriptSegment(
          start: 20,
          speaker: 'SPEAKER_03',
          text: 'First voice again.',
        ),
      ]);

      expect(
        formatted,
        '## Speaker 1\n'
        '\n'
        'First voice.\n'
        'First voice again.\n'
        '\n'
        '## Speaker 2\n'
        '\n'
        'Second voice.',
      );
    });

    test('renders unattributed text in a final section without inventing '
        'a label', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, speaker: 'Speaker 1', text: 'named'),
        TranscriptSegment(start: 7, text: 'unnamed'),
      ]);

      expect(formatted, '## Speaker 1\n\nnamed\n\n## [unattributed]\n\nunnamed');
      expect(formatted, isNot(contains('null')));
    });

    test('unattributed section renders last even when it was spoken first',
        () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, text: 'Mystery opener.'),
        TranscriptSegment(start: 5, speaker: 'Speaker 1', text: 'Named reply.'),
      ]);

      expect(
        formatted,
        '## Speaker 1\n'
        '\n'
        'Named reply.\n'
        '\n'
        '## [unattributed]\n'
        '\n'
        'Mystery opener.',
      );
    });

    test('zero speakers falls back to timestamped paragraphs, never one '
        'giant unattributed section', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, text: 'Solo thought.'),
        TranscriptSegment(start: 61, text: 'Another minute.'),
      ]);

      expect(formatted, '[00:00] Solo thought.\n\n[01:01] Another minute.');
      expect(formatted, isNot(contains('##')));
      expect(formatted, isNot(contains('[unattributed]')));
    });

    test('drops the hours field below one hour and shows it unpadded above '
        '(zero-speaker fallback)', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 3540, text: 'before the hour'),
        TranscriptSegment(start: 3661.9, text: 'after the hour'),
        TranscriptSegment(start: 36000, text: 'ten hours in'),
      ]);

      expect(
        formatted,
        '[59:00] before the hour\n'
        '\n'
        '[1:01:01] after the hour\n'
        '\n'
        '[10:00:00] ten hours in',
      );
    });

    test('floors fractional seconds rather than rounding up '
        '(zero-speaker fallback)', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 59.99, text: 'x'),
      ]);

      expect(formatted, '[00:59] x');
    });

    test('trims each segment text', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, speaker: 'A', text: '  one  '),
        TranscriptSegment(start: 2, speaker: 'A', text: '\ttwo\n'),
      ]);

      expect(formatted, '## Speaker 1\n\none\ntwo');
    });

    test('skips segments whose text is blank after trimming', () {
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(start: 0, speaker: 'A', text: '   '),
        TranscriptSegment(start: 4, speaker: 'A', text: 'kept'),
      ]);

      expect(formatted, '## Speaker 1\n\nkept');
    });

    test('returns null when every segment is blank', () {
      expect(
        formatMeetingTranscript(const [
          TranscriptSegment(start: 0, speaker: 'S', text: '  '),
        ]),
        isNull,
      );
    });

    test('matches the server formatter byte for byte', () {
      // Shared cross-check fixture: the server test suite hardcodes THIS
      // EXACT input and expected string (tests/test_secretary.py,
      // CROSS_CHECK_SEGMENTS / CROSS_CHECK_EXPECTED). If you change either
      // side, change both.
      final formatted = formatMeetingTranscript(const [
        TranscriptSegment(
          start: 12,
          end: 15,
          speaker: 'SPEAKER_07',
          text: 'Second speaker opener.',
        ),
        TranscriptSegment(
          start: 0,
          end: 4,
          speaker: 'SPEAKER_02',
          text: 'Kickoff.',
        ),
        TranscriptSegment(
          start: 7.5,
          end: 11,
          text: 'Crosstalk nobody owns.',
        ),
        TranscriptSegment(
          start: 18,
          end: 21,
          speaker: 'SPEAKER_02',
          text: 'Wrapping up.',
        ),
      ]);

      expect(
        formatted,
        '## Speaker 1\n\nKickoff.\nWrapping up.\n\n'
        '## Speaker 2\n\nSecond speaker opener.\n\n'
        '## [unattributed]\n\nCrosstalk nobody owns.',
      );
    });
  });

  group('formatMeetingTranscriptFromResult', () {
    test('formats a raw server payload end to end', () {
      final formatted = formatMeetingTranscriptFromResult(const [
        {'start': 0.0, 'end': 3.0, 'speaker': 'Speaker 1', 'text': 'Hi.'},
        {'start': 3.0, 'end': 6.0, 'speaker': 'Speaker 1', 'text': 'Again.'},
        {'start': 125.0, 'end': 130.0, 'speaker': 'Speaker 2', 'text': 'Bye.'},
      ]);

      expect(
        formatted,
        '## Speaker 1\n'
        '\n'
        'Hi.\n'
        'Again.\n'
        '\n'
        '## Speaker 2\n'
        '\n'
        'Bye.',
      );
    });

    test('returns null for absent, empty, or unusable payloads', () {
      expect(formatMeetingTranscriptFromResult(null), isNull);
      expect(formatMeetingTranscriptFromResult(const []), isNull);
      expect(formatMeetingTranscriptFromResult('nope'), isNull);
      expect(
        formatMeetingTranscriptFromResult(const [
          {'start': 0.0, 'text': ''},
        ]),
        isNull,
      );
    });
  });
}

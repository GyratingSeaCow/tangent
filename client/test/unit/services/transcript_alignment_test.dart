// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/transcript_alignment.dart';
import 'package:tangent/services/transcript_timings.dart';

TranscriptTimings _t(List<(String, double, double)> words) {
  final w = [
    for (final (text, s, e) in words) '{"w":"$text","s":$s,"e":$e,"p":0.9}',
  ].join(',');
  return TranscriptTimings.parse(
    '[{"start":${words.first.$2},"end":${words.last.$3},"text":"${words.map((x) => x.$1).join(' ')}","words":[$w]}]',
  )!;
}

void main() {
  final timings = _t([
    ('I', 0.0, 0.2),
    ('saw', 0.3, 0.6),
    ('roomy', 0.7, 1.1),
    ('yesterday', 1.2, 1.9),
  ]);

  group('alignTranscript', () {
    test('identical text: every token timed, no insertions', () {
      final a = alignTranscript('I saw roomy yesterday', timings);
      expect(a.tokens.map((t) => t.text), ['I', 'saw', 'roomy', 'yesterday']);
      expect(a.tokens.every((t) => t.start != null), isTrue);
      expect(a.hasInsertions, isFalse);
    });

    test('case and punctuation differences still match', () {
      final a = alignTranscript('i saw Roomy, yesterday.', timings);
      expect(a.tokens.map((t) => t.text), ['i', 'saw', 'Roomy,', 'yesterday.']);
      expect(a.tokens[2].start, 0.7);
      expect(a.hasInsertions, isFalse);
    });

    test('a replaced word takes the deleted word\'s span (roomy → Rumi)', () {
      final a = alignTranscript('I saw Rumi yesterday', timings);
      final rumi = a.tokens[2];
      expect(rumi.text, 'Rumi');
      expect(rumi.start, 0.7);
      expect(rumi.end, 1.1);
      expect(a.hasInsertions, isFalse,
          reason: 'a replacement is not a bare insertion',);
    });

    test('a replaced RUN shares the run\'s span as one block', () {
      final a = alignTranscript('I saw Rumi Smith yesterday', timings);
      // 'roomy' (0.7-1.1) replaced by two words: both get the same span.
      expect(a.tokens[2].text, 'Rumi');
      expect(a.tokens[3].text, 'Smith');
      expect(a.tokens[2].start, 0.7);
      expect(a.tokens[3].start, 0.7);
      expect(a.tokens[3].end, 1.1);
      expect(a.tokens[4].text, 'yesterday');
      expect(a.tokens[4].start, 1.2);
    });

    test('a pure insertion carries no time and flags hasInsertions', () {
      final a = alignTranscript('I saw roomy again yesterday', timings);
      final again = a.tokens[3];
      expect(again.text, 'again');
      expect(again.start, isNull);
      expect(a.hasInsertions, isTrue);
      expect(a.tokens[4].text, 'yesterday');
      expect(a.tokens[4].start, 1.2, reason: 'later words keep their time');
    });

    test('a deletion vanishes; neighbors keep their own time', () {
      final a = alignTranscript('I saw yesterday', timings);
      expect(a.tokens.map((t) => t.text), ['I', 'saw', 'yesterday']);
      expect(a.tokens[2].start, 1.2);
    });

    test('empty transcript: no tokens, no insertions', () {
      final a = alignTranscript('', timings);
      expect(a.tokens, isEmpty);
      expect(a.hasInsertions, isFalse);
    });

    test('confidence rides along on matched tokens', () {
      final a = alignTranscript('I saw roomy yesterday', timings);
      expect(a.tokens[2].confidence, 0.9);
    });

    test('whitespace and newlines are preserved for rendering', () {
      final a = alignTranscript('I saw\nroomy  yesterday', timings);
      expect(a.tokens.map((t) => t.text), ['I', 'saw', 'roomy', 'yesterday']);
      expect(a.tokens[1].trailing, '\n');
      expect(a.tokens[2].trailing, '  ');
    });

    test('currentTokenIndex maps a position through the alignment', () {
      final a = alignTranscript('I saw Rumi again yesterday', timings);
      expect(a.currentTokenIndex(0.9), 2, reason: 'Rumi owns roomy\'s span');
      expect(a.currentTokenIndex(1.5), 4, reason: 'yesterday');
      expect(a.currentTokenIndex(0.25), isNull, reason: 'gap');
    });
  });
}

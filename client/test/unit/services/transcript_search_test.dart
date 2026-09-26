// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/painting.dart' show TextRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/transcript_alignment.dart';
import 'package:tangent/services/transcript_search.dart';
import 'package:tangent/services/transcript_timings.dart';

TranscriptTimings _t(List<(String, double, double)> words) {
  final w = [
    for (final (text, s, e) in words) '{"w":"$text","s":$s,"e":$e,"p":0.9}',
  ].join(',');
  return TranscriptTimings.parse(
    '[{"start":${words.first.$2},"end":${words.last.$3},'
    '"text":"${words.map((x) => x.$1).join(' ')}","words":[$w]}]',
  )!;
}

void main() {
  group('findTranscriptMatches', () {
    test('finds every case-insensitive occurrence in reading order', () {
      final m = findTranscriptMatches('Budget talk: budget, BUDGET!', 'budget');
      expect(m, [
        const TextRange(start: 0, end: 6),
        const TextRange(start: 13, end: 19),
        const TextRange(start: 21, end: 27),
      ]);
    });

    test('blank query or blank text matches nothing', () {
      expect(findTranscriptMatches('anything', '  '), isEmpty);
      expect(findTranscriptMatches('', 'x'), isEmpty);
    });

    test('a quoted phrase query matches the phrase, not each word', () {
      expect(
        findTranscriptMatches('the big plan, a big plan', '"big plan"'),
        hasLength(2),
      );
    });

    test('occurrences do not overlap', () {
      expect(findTranscriptMatches('aaaa', 'aa'), hasLength(2));
    });
  });

  group('parseSnippet', () {
    test('splits FTS5 <b> markers into bold and plain runs', () {
      expect(parseSnippet('…the <b>budget</b> for <b>Budget</b>…'), [
        (text: '…the ', bold: false),
        (text: 'budget', bold: true),
        (text: ' for ', bold: false),
        (text: 'Budget', bold: true),
        (text: '…', bold: false),
      ]);
    });

    test('a snippet without markers is one plain run', () {
      expect(parseSnippet('plain'), [(text: 'plain', bold: false)]);
    });
  });

  group('alignedTokenAt', () {
    final timings = _t([
      ('alpha', 0.0, 0.4),
      ('budget', 0.5, 0.9),
      ('beta', 1.0, 1.4),
    ]);

    test('maps a character offset to the aligned token covering it', () {
      const transcript = '  alpha budget\nbeta';
      final a = alignTranscript(transcript, timings);
      expect(alignedTokenAt(a, transcript, 2), 0); // 'alpha'
      expect(alignedTokenAt(a, transcript, 8), 1); // 'budget'
      expect(alignedTokenAt(a, transcript, 13), 1); // last char of budget
      expect(alignedTokenAt(a, transcript, 15), 2); // 'beta'
    });

    test('an offset past the last token is null', () {
      const transcript = 'alpha budget beta';
      final a = alignTranscript(transcript, timings);
      expect(alignedTokenAt(a, transcript, 17), isNull);
    });
  });

  group('matchSeekSeconds', () {
    test('a match on a timed word yields that word\'s start', () {
      final timings = _t([('alpha', 0.0, 0.4), ('budget', 0.5, 0.9)]);
      const transcript = 'alpha budget';
      final a = alignTranscript(transcript, timings);
      expect(
        matchSeekSeconds(a, transcript, const TextRange(start: 6, end: 12)),
        0.5,
      );
    });

    test('a match on an inserted (untimed) word yields null', () {
      final timings = _t([('alpha', 0.0, 0.4), ('beta', 0.5, 0.9)]);
      const transcript = 'alpha budget beta';
      final a = alignTranscript(transcript, timings);
      expect(
        matchSeekSeconds(a, transcript, const TextRange(start: 6, end: 12)),
        isNull,
      );
    });
  });
}

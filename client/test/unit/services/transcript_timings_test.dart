// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/transcript_timings.dart';

void main() {
  group('TranscriptTimings.parse', () {
    test('reads the server shape: segments with compact words', () {
      final t = TranscriptTimings.parse('''
      {"segments": [
        {"start": 1.0, "end": 2.5, "speaker": "Speaker 1", "text": "Hi there",
         "words": [{"w": "Hi", "s": 1.0, "e": 1.3, "p": 0.98},
                   {"w": "there", "s": 1.4, "e": 2.5, "p": 0.41}]},
        {"start": 3.0, "end": 4.0, "speaker": null, "text": "Bye",
         "words": [{"w": "Bye", "s": 3.0, "e": 4.0, "p": 0.9}]}
      ]}''');
      expect(t, isNotNull);
      expect(t!.segments, hasLength(2));
      expect(t.hasWords, isTrue);
      expect(t.segments.first.speaker, 'Speaker 1');
      expect(t.segments.first.words.map((w) => w.text), ['Hi', 'there']);
      expect(t.segments.first.words[1].confidence, closeTo(0.41, 1e-9));
      expect(t.segments[1].speaker, isNull);
      expect(t.allWords, hasLength(3));
    });

    test('accepts a bare list (the job result_segments shape)', () {
      final t = TranscriptTimings.parse(
        '[{"start": 0, "end": 1, "text": "a", "words": []}]',
      );
      expect(t, isNotNull);
      expect(t!.hasWords, isFalse, reason: 'segment-only data');
    });

    test('segment-only payload (backfilled, words: []) is valid', () {
      final t = TranscriptTimings.parse(
        '{"segments": [{"start": 5, "end": 9, "text": "one sentence", "words": []}]}',
      );
      expect(t!.hasWords, isFalse);
      expect(t.segments.single.text, 'one sentence');
    });

    test('garbage is null, never a throw', () {
      expect(TranscriptTimings.parse(null), isNull);
      expect(TranscriptTimings.parse(''), isNull);
      expect(TranscriptTimings.parse('not json'), isNull);
      expect(TranscriptTimings.parse('42'), isNull);
      expect(TranscriptTimings.parse('{"segments": "nope"}'), isNull);
      expect(TranscriptTimings.parse('{"segments": []}'), isNull,
          reason: 'no segments = no timings',);
    });

    test('drops malformed entries but keeps the good ones', () {
      final t = TranscriptTimings.parse('''
      {"segments": [
        "junk",
        {"start": "x", "text": "bad start"},
        {"start": 1, "end": 2, "text": "ok", "words": [
           {"w": "ok", "s": 1, "e": 2},
           {"w": "", "s": 1, "e": 2},
           {"s": 1, "e": 2},
           {"w": "back", "s": 2, "e": 1}
        ]}
      ]}''');
      expect(t!.segments, hasLength(1));
      expect(t.segments.single.words.map((w) => w.text), ['ok'],
          reason: 'empty word, missing word, and end<start are dropped',);
      expect(t.segments.single.words.single.confidence, 1.0,
          reason: 'missing p defaults to confident',);
    });

    test('round-trips through toJson', () {
      const src =
          '{"segments":[{"start":1.0,"end":2.0,"speaker":"S","text":"t","words":[{"w":"t","s":1.0,"e":2.0,"p":0.5}]}]}';
      final t = TranscriptTimings.parse(src)!;
      final again = TranscriptTimings.parse(t.toJson())!;
      expect(again.segments.single.words.single.confidence, 0.5);
      expect(again.segments.single.speaker, 'S');
    });
  });

  group('currentWordIndex', () {
    final t = TranscriptTimings.parse('''
    {"segments": [
      {"start": 0, "end": 2, "text": "a b", "words": [
        {"w": "a", "s": 0.0, "e": 0.5}, {"w": "b", "s": 1.0, "e": 2.0}]},
      {"start": 3, "end": 4, "text": "c", "words": [
        {"w": "c", "s": 3.0, "e": 4.0}]}
    ]}''')!;

    test('inside a word finds it', () {
      expect(t.currentWordIndex(0.2), 0);
      expect(t.currentWordIndex(1.5), 1);
      expect(t.currentWordIndex(3.9), 2);
    });

    test('a gap between words highlights nothing (silence reads as silence)',
        () {
      expect(t.currentWordIndex(0.7), isNull);
      expect(t.currentWordIndex(2.5), isNull);
    });

    test('before the first word and after the last are nothing', () {
      expect(t.currentWordIndex(-1), isNull);
      expect(t.currentWordIndex(4.01), isNull);
    });

    test('boundaries: start is inclusive, end is exclusive', () {
      expect(t.currentWordIndex(1.0), 1);
      expect(t.currentWordIndex(2.0), isNull);
    });
  });

  group('currentSegmentIndex (segment-only data)', () {
    final t = TranscriptTimings.parse(
      '[{"start": 0, "end": 2, "text": "x", "words": []},'
      ' {"start": 2, "end": 5, "text": "y", "words": []}]',
    )!;
    test('finds the segment by position', () {
      expect(t.currentSegmentIndex(1.0), 0);
      expect(t.currentSegmentIndex(2.0), 1);
      expect(t.currentSegmentIndex(4.99), 1);
      expect(t.currentSegmentIndex(5.0), isNull);
    });
  });

  group('seekTargetFor', () {
    test('leads in by 0.3 s', () {
      expect(seekTargetFor(10.0), const Duration(milliseconds: 9700));
    });
    test('clamps at zero', () {
      expect(seekTargetFor(0.1), Duration.zero);
      expect(seekTargetFor(0.0), Duration.zero);
    });
  });

  group('defaultListenMode', () {
    final withWords = TranscriptTimings.parse(
      '[{"start":0,"end":1,"text":"a","words":[{"w":"a","s":0,"e":1}]}]',
    );
    final segmentsOnly = TranscriptTimings.parse(
      '[{"start":0,"end":1,"text":"a","words":[]}]',
    );
    test('timings + local audio → Listen', () {
      expect(defaultListenMode(timings: withWords, audioLocal: true), isTrue);
      expect(
          defaultListenMode(timings: segmentsOnly, audioLocal: true), isTrue,);
    });
    test('timings without local audio → still Listen (download affordance)',
        () {
      expect(defaultListenMode(timings: withWords, audioLocal: false), isTrue);
    });
    test('no timings → Edit', () {
      expect(defaultListenMode(timings: null, audioLocal: true), isFalse);
      expect(defaultListenMode(timings: null, audioLocal: false), isFalse);
    });
  });

  group('confidenceBucket', () {
    test('buckets per spec: <0.3 strong, <0.5 subtle, else none', () {
      expect(confidenceBucket(0.29), ConfidenceBucket.low);
      expect(confidenceBucket(0.3), ConfidenceBucket.uncertain);
      expect(confidenceBucket(0.49), ConfidenceBucket.uncertain);
      expect(confidenceBucket(0.5), ConfidenceBucket.confident);
      expect(confidenceBucket(1.0), ConfidenceBucket.confident);
    });
  });
}

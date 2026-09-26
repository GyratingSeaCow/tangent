// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/transcript_timings.dart';
import 'package:tangent/widgets/listen_transcript_view.dart';

TranscriptTimings _words() => TranscriptTimings.parse('''
{"segments": [
  {"start": 0.0, "end": 2.0, "speaker": "Speaker 1", "text": "hello big world",
   "words": [{"w":"hello","s":0.0,"e":0.5,"p":0.95},
             {"w":"big","s":0.6,"e":0.9,"p":0.2},
             {"w":"world","s":1.0,"e":2.0,"p":0.45}]},
  {"start": 3.0, "end": 4.0, "speaker": "Speaker 2", "text": "bye",
   "words": [{"w":"bye","s":3.0,"e":4.0,"p":0.9}]}
]}''')!;

TranscriptTimings _segmentsOnly() => TranscriptTimings.parse(
      '[{"start":0,"end":2,"text":"first sentence","words":[]},'
      ' {"start":2,"end":5,"text":"second sentence","words":[]}]',
    )!;

Future<void> _pump(
  WidgetTester tester, {
  required TranscriptTimings? timings,
  required String transcript,
  required ValueNotifier<Duration> position,
  required void Function(Duration) onSeek,
  bool audioLocal = true,
  bool serverPaired = true,
  VoidCallback? onRetranscribe,
  VoidCallback? onDownloadAudio,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: ListenTranscriptView(
              timings: timings,
              transcript: transcript,
              position: position,
              onSeek: onSeek,
              audioLocal: audioLocal,
              serverPaired: serverPaired,
              onRetranscribe: onRetranscribe ?? () {},
              onDownloadAudio: onDownloadAudio,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('tapping a word seeks 0.3 s before it', (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello big world bye',
      position: ValueNotifier(Duration.zero),
      onSeek: seeks.add,
    );
    await tester.tap(find.byKey(const ValueKey('listen-word-2'))); // world
    await tester.pump();
    expect(seeks, [const Duration(milliseconds: 700)]);
  });

  testWidgets('tapping the first word clamps at zero', (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello big world bye',
      position: ValueNotifier(Duration.zero),
      onSeek: seeks.add,
    );
    await tester.tap(find.byKey(const ValueKey('listen-word-0')));
    expect(seeks, [Duration.zero]);
  });

  testWidgets('the highlight follows the playback position', (tester) async {
    final position = ValueNotifier(Duration.zero);
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello big world bye',
      position: position,
      onSeek: (_) {},
    );
    ListenTranscriptViewState state() =>
        tester.state(find.byType(ListenTranscriptView));
    expect(state().highlightedIndex, 0, reason: 't=0 is inside "hello"');

    position.value = const Duration(milliseconds: 1500);
    await tester.pump();
    expect(state().highlightedIndex, 2, reason: '"world"');

    position.value = const Duration(milliseconds: 2500);
    await tester.pump();
    expect(state().highlightedIndex, isNull, reason: 'gap = silence');
  });

  testWidgets('speaker labels appear at each change', (tester) async {
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello big world bye',
      position: ValueNotifier(Duration.zero),
      onSeek: (_) {},
    );
    expect(find.text('Speaker 1'), findsOneWidget);
    expect(find.text('Speaker 2'), findsOneWidget);
  });

  testWidgets('segment-only timings: tap a sentence to seek', (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      timings: _segmentsOnly(),
      transcript: 'first sentence second sentence',
      position: ValueNotifier(Duration.zero),
      onSeek: seeks.add,
    );
    expect(find.byKey(const ValueKey('listen-segment-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('listen-segment-1')));
    expect(seeks, [const Duration(milliseconds: 1700)]);
    expect(
      find.text('Re-transcribe for word timing'),
      findsOneWidget,
      reason: 'upgrade path offered when only sentences are timed',
    );
  });

  testWidgets('no timings at all: plain text plus the re-transcribe action',
      (tester) async {
    var retranscribed = 0;
    await _pump(
      tester,
      timings: null,
      transcript: 'untimed words here',
      position: ValueNotifier(Duration.zero),
      onSeek: (_) {},
      onRetranscribe: () => retranscribed++,
    );
    expect(find.text('untimed words here'), findsOneWidget);
    await tester.tap(find.text('Re-transcribe for word timing'));
    expect(retranscribed, 1);
  });

  testWidgets('no timings and no server: no dead re-transcribe button',
      (tester) async {
    await _pump(
      tester,
      timings: null,
      transcript: 'untimed',
      position: ValueNotifier(Duration.zero),
      onSeek: (_) {},
      serverPaired: false,
    );
    expect(find.text('Re-transcribe for word timing'), findsNothing);
  });

  testWidgets('audio not local: words render, download affordance shown',
      (tester) async {
    var downloads = 0;
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello big world bye',
      position: ValueNotifier(Duration.zero),
      onSeek: (_) {},
      audioLocal: false,
      onDownloadAudio: () => downloads++,
    );
    expect(find.byKey(const ValueKey('listen-word-0')), findsOneWidget);
    await tester.tap(find.text('Download audio to play'));
    expect(downloads, 1);
  });

  testWidgets('edited transcript: insertions render untimed, caption shown',
      (tester) async {
    final seeks = <Duration>[];
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello really big world bye',
      position: ValueNotifier(Duration.zero),
      onSeek: seeks.add,
    );
    expect(find.text('really'), findsOneWidget);
    await tester.tap(find.text('really'));
    expect(seeks, isEmpty, reason: 'an inserted word has no moment');
    expect(find.textContaining('Timings follow your edits'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('listen-word-3'))); // world
    expect(
      seeks,
      [const Duration(milliseconds: 700)],
      reason: 'later matched words keep their own time',
    );
  });

  testWidgets('low-confidence words are tinted per bucket', (tester) async {
    await _pump(
      tester,
      timings: _words(),
      transcript: 'hello big world bye',
      position: ValueNotifier(Duration.zero),
      onSeek: (_) {},
    );
    ListenTranscriptViewState state() =>
        tester.state(find.byType(ListenTranscriptView));
    expect(state().bucketFor(0), ConfidenceBucket.confident); // hello .95
    expect(state().bucketFor(1), ConfidenceBucket.low); // big .2
    expect(state().bucketFor(2), ConfidenceBucket.uncertain); // world .45
  });
}

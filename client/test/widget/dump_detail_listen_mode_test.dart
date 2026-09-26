// SPDX-License-Identifier: AGPL-3.0-or-later
/// Tap-to-hear on the detail screen (spec §3.3): the Edit | Listen toggle
/// exists only when timings exist, Listen is the default when they do,
/// and a word tap reaches the playback engine as seek-then-play.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/widgets/listen_transcript_view.dart';

import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/storage_fixture.dart';

final class SpyPlayer implements RecordingPlaybackEngine {
  bool loaded = false;
  final seeks = <Duration>[];
  int plays = 0;
  final _playing = StreamController<bool>.broadcast();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<Duration?> load(AudioLocator source) async {
    loaded = true;
    return const Duration(seconds: 3);
  }

  @override
  Future<void> play() async {
    plays++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> dispose() async => _playing.close();
}

const _timings = '{"segments":[{"start":0.0,"end":2.0,"text":"retained words",'
    '"words":[{"w":"retained","s":0.0,"e":1.0,"p":0.9},'
    '{"w":"words","s":1.2,"e":2.0,"p":0.9}]}]}';

Future<(StorageFixture, BoundServiceFixture, SpyPlayer)> _mount(
  WidgetTester tester, {
  required String? timings,
}) async {
  final f = StorageFixture.create();
  final bound = await createBoundServiceFixture(f.db, registerDrain: false);
  final player = SpyPlayer();
  addTearDown(() async {
    await disposeBoundWidget(tester, bound);
    await tester.runAsync(f.close);
  });
  final a = (await tester.runAsync(
    () => f.seed('fixture-listen', status: 'completed'),
  ))!;
  if (timings != null) {
    await tester.runAsync(
      () => (f.db.update(f.db.dumps)..where((d) => d.id.equals(a.key.dumpId)))
          .write(DumpsCompanion(transcriptTimings: Value(timings))),
    );
  }
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localDbProvider.overrideWithValue(f.db),
        recordingAccessProvider.overrideWithValue(bound.access),
        recordingMutationsProvider.overrideWithValue(bound.mutations),
        localDeletionServiceProvider.overrideWithValue(
          DefaultLocalDeletionService(
            db: f.db,
            backend: f.backend,
            mutations: bound.mutations,
          ),
        ),
        recordingPlaybackEngineFactoryProvider.overrideWithValue(() => player),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Library')),
      ),
    ),
  );
  unawaited(
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => DumpDetailScreen(
          dumpId: a.key.dumpId,
          audioPath: a.audio.value,
          durationSeconds: 3,
        ),
      ),
    ),
  );
  await pumpBoundUntil(tester, () => player.loaded);
  await tester.pumpAndSettle();
  return (f, bound, player);
}

void main() {
  testWidgets('no timings: no toggle, editor as before', (tester) async {
    await _mount(tester, timings: null);
    expect(
      find.byKey(const ValueKey('listen-toggle-fixture-listen')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('transcript-editor-fixture-listen')),
      findsOneWidget,
    );
    expect(find.byType(ListenTranscriptView), findsNothing);
    // Unmount inside the test body so Drift stream-close timers flush before
    // the framework's pending-timer invariant (dump_detail pattern).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'timings present: Listen is the default and a word tap '
      'seeks 0.3 s early then plays', (tester) async {
    final (_, _, player) = await _mount(tester, timings: _timings);
    expect(
      find.byKey(const ValueKey('listen-toggle-fixture-listen')),
      findsOneWidget,
    );
    expect(find.byType(ListenTranscriptView), findsOneWidget);
    expect(
      find.byKey(const ValueKey('transcript-editor-fixture-listen')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('listen-word-1'))); // words
    await tester.pumpAndSettle();
    expect(player.seeks, [const Duration(milliseconds: 900)]);
    expect(player.plays, 1, reason: 'a tap means play, not just move');
    // Unmount inside the test body so Drift stream-close timers flush before
    // the framework's pending-timer invariant (dump_detail pattern).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the waveform scrubber is mounted in Listen and seeks',
      (tester) async {
    final (_, _, player) = await _mount(tester, timings: _timings);
    final strip = find.byKey(const ValueKey('waveform-fixture-listen'));
    expect(strip, findsOneWidget);
    final box = tester.getRect(strip);
    // Row duration is 3 s; tap at the midpoint → 1.5 s, no lead-in.
    await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
    await tester.pumpAndSettle();
    expect(player.seeks, [const Duration(milliseconds: 1500)]);
    expect(player.plays, 1);
    // Unmount inside the test body so Drift stream-close timers flush before
    // the framework's pending-timer invariant (dump_detail pattern).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('Edit brings the editor back; Listen returns', (tester) async {
    await _mount(tester, timings: _timings);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('transcript-editor-fixture-listen')),
      findsOneWidget,
    );
    expect(find.byType(ListenTranscriptView), findsNothing);
    await tester.tap(find.text('Listen'));
    await tester.pumpAndSettle();
    expect(find.byType(ListenTranscriptView), findsOneWidget);
    // Unmount inside the test body so Drift stream-close timers flush before
    // the framework's pending-timer invariant (dump_detail pattern).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// The detail screen opened from a search hit (search-depth spec §2): a
/// match bar counts the hits, prev/next wrap at both ends, and the play
/// affordance exists only when the matched word has a moment to play —
/// then seeks 0.3 s before it, never below zero.
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

const _transcript = 'budget first then budget again and budget last';

/// The first "budget" starts at 0.1 s, so its lead-in must clamp to zero;
/// the second at 1.0 s seeks to 0.7 s.
const _timings = '{"segments":[{"start":0.0,"end":3.0,"text":"$_transcript",'
    '"words":[{"w":"budget","s":0.1,"e":0.4,"p":0.9},'
    '{"w":"first","s":0.4,"e":0.6,"p":0.9},'
    '{"w":"then","s":0.6,"e":1.0,"p":0.9},'
    '{"w":"budget","s":1.0,"e":1.4,"p":0.9},'
    '{"w":"again","s":1.4,"e":1.8,"p":0.9},'
    '{"w":"and","s":1.8,"e":2.0,"p":0.9},'
    '{"w":"budget","s":2.0,"e":2.4,"p":0.9},'
    '{"w":"last","s":2.4,"e":3.0,"p":0.9}]}]}';

Future<SpyPlayer> _mount(
  WidgetTester tester, {
  required String? timings,
  String? query = 'budget',
}) async {
  final f = StorageFixture.create();
  final bound = await createBoundServiceFixture(f.db, registerDrain: false);
  final player = SpyPlayer();
  addTearDown(() async {
    await disposeBoundWidget(tester, bound);
    await tester.runAsync(f.close);
  });
  final a = (await tester.runAsync(
    () => f.seed('fixture-search', status: 'completed'),
  ))!;
  await tester.runAsync(
    () => (f.db.update(f.db.dumps)..where((d) => d.id.equals(a.key.dumpId)))
        .write(
      DumpsCompanion(
        transcript: const Value(_transcript),
        transcriptTimings: Value(timings),
      ),
    ),
  );
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
          initialSearchQuery: query,
        ),
      ),
    ),
  );
  await pumpBoundUntil(tester, () => player.loaded);
  await tester.pumpAndSettle();
  return player;
}

Future<void> _unmount(WidgetTester tester) async {
  // Unmount inside the test body so Drift stream-close timers flush before
  // the framework's pending-timer invariant (dump_detail pattern).
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

String _label(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('transcript-match-label')))
    .data!;

void main() {
  testWidgets('no query: no match bar', (tester) async {
    await _mount(tester, timings: null, query: null);
    expect(find.byKey(const ValueKey('transcript-match-bar')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('counts the hits and wraps at both ends', (tester) async {
    await _mount(tester, timings: null);
    expect(find.byKey(const ValueKey('transcript-match-bar')), findsOneWidget);
    expect(_label(tester), '1 of 3');

    final next = find.byKey(const ValueKey('transcript-match-next'));
    final prev = find.byKey(const ValueKey('transcript-match-prev'));
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(_label(tester), '2 of 3');
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(_label(tester), '3 of 3');
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(_label(tester), '1 of 3', reason: 'next wraps 3 -> 1');
    await tester.tap(prev);
    await tester.pumpAndSettle();
    expect(_label(tester), '3 of 3', reason: 'prev wraps 1 -> 3');
    await _unmount(tester);
  });

  testWidgets('play affordance only with word timings', (tester) async {
    await _mount(tester, timings: null);
    expect(find.byKey(const ValueKey('transcript-match-play')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('play seeks 0.3 s before the matched word, clamped at zero',
      (tester) async {
    final player = await _mount(tester, timings: _timings);
    final play = find.byKey(const ValueKey('transcript-match-play'));
    expect(play, findsOneWidget);

    // Match 1: word starts at 0.1 s -> 0.1 - 0.3 clamps to 0.
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(player.seeks, [Duration.zero]);
    expect(player.plays, 1);

    // Match 2: word starts at 1.0 s -> 0.7 s.
    await tester.tap(find.byKey(const ValueKey('transcript-match-next')));
    await tester.pumpAndSettle();
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(player.seeks, [Duration.zero, const Duration(milliseconds: 700)]);
    await _unmount(tester);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// Pinned playback controls: on a recording, the playback panel (and in
/// Listen mode the waveform scrubber) sits in a fixed header ABOVE the
/// scrolling list, so the user can pause from anywhere in a long
/// transcript. Notes keep the plain single-list layout — they have no
/// playback at all.
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

final class _StubEngine implements RecordingPlaybackEngine {
  bool loaded = false;
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
  Future<void> play() async => _playing.add(true);
  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async => _playing.close();
}

const _timings = '{"segments":[{"start":0.0,"end":2.0,"text":"retained words",'
    '"words":[{"w":"retained","s":0.0,"e":1.0,"p":0.9},'
    '{"w":"words","s":1.2,"e":2.0,"p":0.9}]}]}';

/// A transcript long enough that the list must scroll on the test viewport.
final _longTranscript =
    List.generate(80, (i) => 'line $i of a very long transcript').join('\n');

/// Mounts the detail screen for the fixture row seeded by [prepare].
///
/// [waitForPlayer] is false for notes: a text note never opens a playback
/// engine, so waiting on `player.loaded` would hang forever.
Future<StorageFixture> _mount(
  WidgetTester tester, {
  String? timings,
  String? transcript,
  String? mode,
  bool waitForPlayer = true,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final f = StorageFixture.create();
  final bound = await createBoundServiceFixture(f.db, registerDrain: false);
  final player = _StubEngine();
  addTearDown(() async {
    await disposeBoundWidget(tester, bound);
    await tester.runAsync(f.close);
  });
  final a = (await tester.runAsync(
    () => f.seed('fixture-pinned', status: 'completed'),
  ))!;
  await tester.runAsync(
    () => (f.db.update(f.db.dumps)
          ..where((d) => d.id.equals(a.key.dumpId)))
        .write(
      DumpsCompanion(
        transcriptTimings: Value(timings),
        transcript: transcript == null ? const Value.absent() : Value(transcript),
        mode: mode == null ? const Value.absent() : Value(mode),
      ),
    ),
  );
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
        home: DumpDetailScreen(
          dumpId: a.key.dumpId,
          audioPath: a.audio.value,
          durationSeconds: 3,
        ),
      ),
    ),
  );
  if (waitForPlayer) {
    await pumpBoundUntil(tester, () => player.loaded);
  } else {
    await pumpBoundUntil(
      tester,
      () => find
          .byKey(const ValueKey('title-editor-fixture-pinned'))
          .evaluate()
          .isNotEmpty,
    );
  }
  await tester.pumpAndSettle();
  return f;
}

/// Scrolls the page's OUTER list to its bottom and asserts it really had
/// somewhere to go — a non-scrolling layout fails here, so the pinned
/// assertions below cannot pass vacuously.
Future<void> _scrollToBottom(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;
  expect(
    position.maxScrollExtent,
    greaterThan(0),
    reason: 'the page must actually be scrollable for this test to mean '
        'anything',
  );
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

/// The visible screen in logical pixels (viewport set in [_mount]).
const _screen = Rect.fromLTWH(0, 0, 800, 600);

void _expectOnScreen(WidgetTester tester, Finder finder, String what) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  expect(
    _screen.contains(rect.topLeft) && _screen.contains(rect.bottomRight),
    isTrue,
    reason: '$what must stay within the viewport after scrolling, got $rect',
  );
}

void main() {
  testWidgets(
      'recording (edit mode): playback panel stays on screen after '
      'scrolling a long transcript to the bottom', (tester) async {
    await _mount(tester, transcript: _longTranscript);
    // Sanity: the title editor starts visible at the top of the list.
    expect(
      find.byKey(const ValueKey('title-editor-fixture-pinned')).hitTestable(),
      findsOneWidget,
    );

    await _scrollToBottom(tester);

    // The list content really scrolled: the title editor left the screen.
    expect(
      find.byKey(const ValueKey('title-editor-fixture-pinned')).hitTestable(),
      findsNothing,
      reason: 'the top of the list must scroll away',
    );
    // The pinned header did not: pause/play is still reachable.
    _expectOnScreen(
      tester,
      find.text('Recording playback'),
      'the playback panel',
    );

    // Unmount inside the test body so Drift stream-close timers flush before
    // the framework's pending-timer invariant (dump_detail pattern).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'recording (Listen mode): panel AND waveform scrubber stay on screen '
      'after scrolling to the bottom', (tester) async {
    await _mount(tester, timings: _timings);
    expect(
      find.byKey(const ValueKey('title-editor-fixture-pinned')).hitTestable(),
      findsOneWidget,
    );

    await _scrollToBottom(tester);

    expect(
      find.byKey(const ValueKey('title-editor-fixture-pinned')).hitTestable(),
      findsNothing,
      reason: 'the top of the list must scroll away',
    );
    _expectOnScreen(
      tester,
      find.text('Recording playback'),
      'the playback panel',
    );
    _expectOnScreen(
      tester,
      find.byKey(const ValueKey('waveform-fixture-pinned')),
      'the waveform scrubber',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('note: no pinned header — the single-list layout stands',
      (tester) async {
    await _mount(
      tester,
      transcript: _longTranscript,
      mode: 'text_note',
      waitForPlayer: false,
    );
    expect(
      find.byKey(const ValueKey('pinned-playback-layout-fixture-pinned')),
      findsNothing,
      reason: 'notes have no playback, so nothing may be pinned',
    );
    expect(find.text('Recording playback'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

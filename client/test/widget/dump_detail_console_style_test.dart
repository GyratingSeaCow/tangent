// SPDX-License-Identifier: AGPL-3.0-or-later
/// Instrument Console v2 — the recording detail screen adopts the shared
/// chrome: the top nav rail with Recordings lit (a pushed detail still
/// belongs to its root), the global create key, the transport in a bordered
/// panel, meta info as chips, the Edit|Listen toggle in the signal
/// treatment, and the AI summary card carrying a signal accent. Styling
/// only: every control keeps its key, text and behaviour.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/theme/tangent_tokens.dart';
import 'package:tangent/widgets/instrument_scaffold.dart';
import 'package:tangent/widgets/top_nav_rail.dart';

import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/legacy_audio_storage_fixture.dart';
import '../support/resolved_temp.dart';

final class _StubEngine implements RecordingPlaybackEngine {
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<Duration?> load(AudioLocator source) async =>
      const Duration(seconds: 4);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

const String _timings =
    '{"segments":[{"start":0.0,"end":2.0,"text":"hello words",'
    '"words":[{"w":"hello","s":0.0,"e":1.0,"p":0.9},'
    '{"w":"words","s":1.2,"e":2.0,"p":0.9}]}]}';

void main() {
  void useHandsetViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  DumpRow row(
    AudioStorage storage,
    String id, {
    String mode = 'brain_dump',
    String? transcript = 'hello words',
    String? timings,
    String? summary,
  }) =>
      DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 24),
        updatedAt: DateTime.utc(2026, 9, 24),
        mode: mode,
        durationSeconds: 4,
        title: 'Console restyle',
        audioPath: storage.pathFor(id).path,
        audioSizeBytes: 3,
        syncStatus: 'synced',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionAttempt: 1,
        transcript: transcript,
        transcriptTimings: timings,
        summary: summary,
        summaryModel: summary == null ? null : 'Qwen3-4B-Instruct-2507-Q4_K_M',
        summarizedAt: summary == null ? null : 1790000000,
      );

  Future<void> mountDetail(WidgetTester tester, DumpRow seedRow) async {
    final temp = createResolvedTempSync('tangent-console-detail-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final seeded = seedRow.copyWith(
      audioPath: storage.pathFor(seedRow.id).path,
    );
    await seedFileFixtureRow(db, seeded);
    storage.pathFor(seedRow.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          dumpByIdProvider(seedRow.id).overrideWith(
            (ref) => Stream<DumpRow?>.value(seeded),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: seedRow.id,
            audioPath: seeded.audioPath,
            durationSeconds: seedRow.durationSeconds,
          ),
        ),
      ),
    );
    await pumpBoundUntil(
      tester,
      () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'the detail screen sits under the nav rail with Recordings lit and '
      'keeps the global create key', (tester) async {
    useHandsetViewport(tester);
    final temp = createResolvedTempSync('tangent-console-rail-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(tester, row(storage, 'rail-1'));

    // All six destinations are present above the screen's own app bar.
    for (final TangentRoot root in TangentRoot.values) {
      expect(find.byKey(railKey(root)), findsOneWidget);
    }

    // Recordings is the lit root: a no-op in the signal colour.
    final IconButton recordings = tester.widget<IconButton>(
      find.byKey(railKey(TangentRoot.recordings)),
    );
    expect(
      recordings.onPressed,
      isNull,
      reason: 'the active destination is a no-op',
    );
    expect(
      recordings.disabledColor,
      TangentColors.signal,
      reason: 'the active destination is lit, not greyed',
    );

    // Any other destination stays tappable.
    final IconButton capture = tester.widget<IconButton>(
      find.byKey(railKey(TangentRoot.capture)),
    );
    expect(capture.onPressed, isNotNull);

    // The detail screen keeps the global create key (only the notebook
    // editor suppresses it for stylus space).
    expect(find.byKey(InstrumentScaffold.createFabKey), findsOneWidget);

    // The screen's own app bar survives: back-capable chrome with delete.
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'the transport sits in a bordered rounded panel, meta info renders as '
      'chips, and the Edit|Listen toggle wears the signal treatment',
      (tester) async {
    useHandsetViewport(tester);
    final temp = createResolvedTempSync('tangent-console-transport-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(tester, row(storage, 'tr-1', timings: _timings));

    // Transport panel: edge border, panel radius — machined, not a Card.
    final Container panel = tester.widget<Container>(
      find.byKey(const ValueKey<String>('transport-panel')),
    );
    final BoxDecoration deco = panel.decoration! as BoxDecoration;
    expect(deco.border, isNotNull);
    expect(
      (deco.border! as Border).top.color,
      TangentColors.edge,
      reason: 'the transport panel wears the hairline edge',
    );
    expect(
      deco.borderRadius,
      BorderRadius.circular(TangentShapes.panelRadius),
    );
    expect(
      find.text('Recording playback'),
      findsOneWidget,
      reason: 'the transport keeps its title',
    );

    // Meta line renders as chips (mode, duration, status at minimum).
    expect(
      find.byType(Chip),
      findsAtLeastNWidgets(3),
      reason: 'mode, duration and sync status read as chips',
    );

    // Edit | Listen: the active segment takes the quiet tinted pill with
    // the signal foreground; inactive segments stay dim.
    final SegmentedButton<bool> toggle = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    final ButtonStyle style = toggle.style!;
    expect(
      style.backgroundColor!.resolve(<WidgetState>{WidgetState.selected}),
      TopNavRail.activeTint,
    );
    expect(
      style.foregroundColor!.resolve(<WidgetState>{WidgetState.selected}),
      TangentColors.signal,
    );
    expect(
      style.foregroundColor!.resolve(const <WidgetState>{}),
      TangentColors.textDim,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the AI summary card carries the 3px signal left accent',
      (tester) async {
    useHandsetViewport(tester);
    final temp = createResolvedTempSync('tangent-console-summary-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(
      tester,
      row(
        storage,
        'sum-acc',
        mode: 'meeting',
        transcript: '[00:00] Alice: hello and welcome',
        summary: '## Summary\nShip the beta.',
      ),
    );

    final Container accent = tester.widget<Container>(
      find.byKey(const ValueKey('ai-summary-accent-sum-acc')),
    );
    final BoxDecoration deco = accent.decoration! as BoxDecoration;
    final Border border = deco.border! as Border;
    expect(border.left.color, TangentColors.signal);
    expect(border.left.width, TangentShapes.bezelWidth);
    expect(
      border.top.width,
      0,
      reason: 'the accent is a LEFT bezel only',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

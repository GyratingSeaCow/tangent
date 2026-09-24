// SPDX-License-Identifier: AGPL-3.0-or-later
/// Task 4: the dump detail renders the server-generated AI summary BELOW
/// the transcript, under a deliberately subtle header — and a dump without
/// a summary renders exactly as it did before the feature existed. The
/// summary is server-owned and arrives via normal dump sync; this screen
/// only presents it.
library;

import 'dart:io';

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

import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/legacy_audio_storage_fixture.dart';

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

const String _summaryMarkdown = '## Summary\n'
    'Team discussed the roadmap and agreed to ship the beta.\n'
    '\n'
    '## Action items\n'
    '- Alice: prepare the release notes';

void main() {
  void useHandsetViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// A transcribed meeting recording, optionally carrying a synced summary.
  DumpRow meetingRow(
    AudioStorage storage,
    String id, {
    String? summary,
  }) =>
      DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 24),
        updatedAt: DateTime.utc(2026, 9, 24),
        mode: 'meeting',
        durationSeconds: 4,
        title: 'Sprint planning',
        audioPath: storage.pathFor(id).path,
        audioSizeBytes: 3,
        syncStatus: 'synced',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionAttempt: 1,
        transcript: '[00:00] Alice: hello and welcome to planning',
        summary: summary,
        summaryModel: summary == null ? null : 'Qwen3-4B-Instruct-2507-Q4_K_M',
        summarizedAt: summary == null ? null : 1790000000,
      );

  Future<void> mountDetail(WidgetTester tester, DumpRow row) async {
    final temp = Directory.systemTemp.createTempSync('tangent-summary-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final seeded = row.copyWith(audioPath: storage.pathFor(row.id).path);
    await seedFileFixtureRow(db, seeded);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          dumpByIdProvider(row.id).overrideWith(
            (ref) => Stream<DumpRow?>.value(seeded),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
            audioPath: seeded.audioPath,
            durationSeconds: row.durationSeconds,
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
      'a synced summary renders below the transcript under a subtle '
      'AI summary header', (tester) async {
    useHandsetViewport(tester);
    final temp = Directory.systemTemp.createTempSync('tangent-summary-row-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final row = meetingRow(storage, 'sum-1', summary: _summaryMarkdown);
    await mountDetail(tester, row);

    expect(
      find.byKey(const ValueKey('ai-summary-header-sum-1')),
      findsOneWidget,
      reason: 'a dump carrying a summary must present it',
    );
    expect(find.text('AI summary'), findsOneWidget);
    final SelectableText body = tester.widget<SelectableText>(
      find.byKey(const ValueKey('ai-summary-body-sum-1')),
    );
    expect(
      body.data,
      contains('Team discussed the roadmap'),
      reason: 'the summary body is the synced markdown, verbatim',
    );

    // BELOW the transcript, per spec §1: transcript first, then summary.
    final double transcriptY = tester
        .getTopLeft(find.byKey(const ValueKey('transcript-header-sum-1')))
        .dy;
    final double summaryY = tester
        .getTopLeft(find.byKey(const ValueKey('ai-summary-header-sum-1')))
        .dy;
    expect(
      summaryY,
      greaterThan(transcriptY),
      reason: 'the summary block must sit below the transcript',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'absent-safe: a dump without a summary renders no AI summary header '
      'or body', (tester) async {
    useHandsetViewport(tester);
    final temp = Directory.systemTemp.createTempSync('tangent-summary-null-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final row = meetingRow(storage, 'sum-2', summary: null);
    await mountDetail(tester, row);

    expect(
      find.byKey(const ValueKey('ai-summary-header-sum-2')),
      findsNothing,
      reason: 'a null summary must render exactly as before the feature',
    );
    expect(find.text('AI summary'), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-summary-body-sum-2')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

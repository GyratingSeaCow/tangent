// SPDX-License-Identifier: AGPL-3.0-or-later
/// Leftovers sweep (2026-09-28) L1 + L3 on the dump detail screen.
///
/// L1: 'Regenerate notes' uses the AI summarizer (Meeting template, the
/// existing summarize path) when the server reports it installed and the
/// capability is on; otherwise the on-device extractor runs exactly as
/// before. The in-progress card names the engine.
///
/// L3: the extractor's digest is built from the transcript rendered through
/// the dump's speaker-name map, so the notes say "Jeff" not "Speaker 1";
/// the STORED transcript stays raw.
library;

import 'dart:async';
import 'dart:convert';

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
import 'package:tangent/screens/settings/ai_summaries_section.dart';
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/services/summaries_client.dart';

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

/// Records every summarize POST and answers the settings poll with a fixed
/// `installed` flag (the readiness the Summarize button already checks).
class _FakeSummariesClient extends SummariesClient {
  _FakeSummariesClient({required this.installed})
      : super(baseUrl: 'http://unused.invalid');

  final bool installed;
  int settingsPolls = 0;
  final List<(String, String?)> summarizeCalls = <(String, String?)>[];

  @override
  Future<SummarySettings> getSettings() async {
    settingsPolls += 1;
    return SummarySettings(
      installed: installed,
      runtime: installed ? 'cpu' : null,
      gpuVisible: false,
      diskFreeBytes: 1 << 40,
      installRunning: false,
      enabled: true,
    );
  }

  @override
  Future<void> summarizeDump(String dumpId, {String? template}) async {
    summarizeCalls.add((dumpId, template));
  }
}

/// Straight from the formatter: raw labels only, with one decision so the
/// extractor has something to quote.
const String _rawTranscript = '## Speaker 1\n'
    'We decided to launch the beta on Friday.\n'
    '\n'
    '## Speaker 2\n'
    'Anything else?\n';

const String _oldNotes = '# Old\n\n## Summary\n\nStale digest.';

void main() {
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  DumpRow meetingRow(
    AudioStorage storage,
    String id, {
    String? speakerNames,
  }) =>
      DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 28),
        updatedAt: DateTime.utc(2026, 9, 28),
        mode: 'meeting',
        durationSeconds: 4,
        title: 'Sprint planning',
        audioPath: storage.pathFor(id).path,
        audioSizeBytes: 3,
        syncStatus: 'synced',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionAttempt: 1,
        transcriptionRequestId: 'request-$id',
        transcript: _rawTranscript,
        meetingNotes: _oldNotes,
        speakerNames: speakerNames,
      );

  /// A REAL row stream (db.watchDump) and a real bound-service fixture, so
  /// the extractor's write and the AI path's request marker both reach the
  /// screen the way they do in production.
  Future<
      ({
        LocalDb db,
        AudioStorage storage,
        _FakeSummariesClient client,
        DumpRow row,
      })> mount(
    WidgetTester tester,
    String id, {
    required bool installed,
    bool capability = true,
    String? speakerNames,
  }) async {
    useTallViewport(tester);
    kNotesBusyMinimum = const Duration(milliseconds: 100);
    addTearDown(() => kNotesBusyMinimum = const Duration(milliseconds: 600));
    final temp = createResolvedTempSync('tangent-regen-notes-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final client = _FakeSummariesClient(installed: installed);
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = meetingRow(storage, id, speakerNames: speakerNames);
    await seedFileFixtureRow(db, row);
    storage.pathFor(id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          audioStorageProvider.overrideWithValue(storage),
          dumpByIdProvider(id).overrideWith((ref) => db.watchDump(id)),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
          summariesEnabledProvider.overrideWith((ref) => capability),
          summariesClientProvider.overrideWith(
            (ref) => Future<SummariesClient>.value(client),
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: id,
            audioPath: row.audioPath,
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
    return (db: db, storage: storage, client: client, row: row);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Finder regenerate(String id) => find.byKey(ValueKey('regenerate-notes-$id'));
  Finder engineLabel(String id) =>
      find.byKey(ValueKey('regenerate-notes-engine-label-$id'));

  /// Presses the button and waits (real time: the extractor path does
  /// filesystem I/O through the bound fixture) until [done] holds.
  Future<void> pressAndWait(
    WidgetTester tester,
    String id,
    FutureOr<bool> Function() done,
  ) async {
    final button = tester.widget<OutlinedButton>(regenerate(id));
    // Fire, don't await: the extractor's edit lease settles through the
    // pumped test zone, so awaiting the whole handler inside runAsync
    // would deadlock (the existing meeting-detail test does the same).
    await tester.runAsync(() async {
      // ignore: unawaited_futures
      button.onPressed!();
    });
    await tester.pump();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final bool? finished = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return await done();
      });
      await tester.pump(const Duration(milliseconds: 10));
      if (finished == true) return;
      if (DateTime.now().isAfter(deadline)) {
        fail('regenerate notes did not finish');
      }
    }
  }

  testWidgets(
      'L1 installed: one summarize request with template meeting, no '
      'extractor call; the in-progress card names "AI summary (Meeting)"',
      (tester) async {
    final live = await mount(tester, 'regen-ai', installed: true);

    await pressAndWait(
      tester,
      'regen-ai',
      () => live.client.summarizeCalls.isNotEmpty,
    );
    // The card sits on the meeting-notes block while the server writes.
    expect(engineLabel('regen-ai'), findsOneWidget);
    expect(
      tester.widget<Text>(engineLabel('regen-ai')).data,
      contains('AI summary (Meeting)'),
    );
    expect(
      live.client.summarizeCalls,
      <(String, String?)>[('regen-ai', 'meeting')],
      reason: 'exactly one request, with the Meeting template',
    );
    expect(live.client.settingsPolls, 1, reason: 'the readiness check');
    expect(
      find.byKey(const ValueKey('notes-ai-queued-snack')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('notes-regenerated-snack')),
      findsNothing,
      reason: 'the extractor did not run',
    );

    final DumpRow? after = await tester.runAsync<DumpRow?>(
      () => live.db.getDump('regen-ai'),
    );
    expect(
      after!.meetingNotes,
      _oldNotes,
      reason: 'no extractor call: the notes wait for the worker',
    );
    expect(after.summaryRequestedAt, isNotNull, reason: '202 stamped');
    expect(after.summaryTemplate, 'meeting');
    expect(after.transcript, _rawTranscript, reason: 'stored transcript');
    // The AI in-progress strip is the ordinary summarize one.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('ai-summary-pending-regen-ai')),
      findsOneWidget,
    );
    expect(
      tester.widget<OutlinedButton>(regenerate('regen-ai')).onPressed,
      isNotNull,
      reason: 'the button re-enables once the request is queued',
    );
    await unmount(tester);
  });

  testWidgets(
      'L1 not installed: the extractor runs and no summarize request is '
      'sent; the in-progress card names "Quick notes"', (tester) async {
    final live = await mount(tester, 'regen-quick', installed: false);

    final List<String?> labelsSeen = <String?>[];
    await pressAndWait(tester, 'regen-quick', () {
      final Iterable<Element> found = engineLabel('regen-quick').evaluate();
      if (found.isNotEmpty) {
        labelsSeen.add((found.single.widget as Text).data);
      }
      return find
          .byKey(const ValueKey('notes-regenerated-snack'))
          .evaluate()
          .isNotEmpty;
    });

    expect(live.client.settingsPolls, 1, reason: 'the readiness check');
    expect(live.client.summarizeCalls, isEmpty, reason: 'no request');
    expect(
      labelsSeen,
      isNotEmpty,
      reason: 'the in-progress card appeared while the extractor ran',
    );
    expect(labelsSeen, everyElement(contains('Quick notes')));
    expect(labelsSeen, isNot(anyElement(contains('AI summary'))));
    expect(
      find.byKey(const ValueKey('notes-ai-queued-snack')),
      findsNothing,
    );

    final DumpRow? after = await tester.runAsync<DumpRow?>(
      () => live.db.getDump('regen-quick'),
    );
    expect(after!.meetingNotes, isNot(_oldNotes), reason: 'extractor wrote');
    expect(after.meetingNotes, contains('# Sprint planning'));
    expect(
      after.meetingNotes,
      contains('We decided to launch the beta on Friday.'),
    );
    expect(after.summaryRequestedAt, isNull, reason: 'no 202 to stamp');
    expect(after.transcript, _rawTranscript);
    await unmount(tester);
  });

  testWidgets(
      'L1 capability off: the extractor runs without even polling the '
      'server', (tester) async {
    final live = await mount(
      tester,
      'regen-off',
      installed: true,
      capability: false,
    );

    await pressAndWait(
      tester,
      'regen-off',
      () => find
          .byKey(const ValueKey('notes-regenerated-snack'))
          .evaluate()
          .isNotEmpty,
    );

    expect(live.client.settingsPolls, 0);
    expect(live.client.summarizeCalls, isEmpty);
    final DumpRow? after = await tester.runAsync<DumpRow?>(
      () => live.db.getDump('regen-off'),
    );
    expect(after!.meetingNotes, isNot(_oldNotes));
    await unmount(tester);
  });

  testWidgets(
      'L3: map {Speaker 1: Jeff} → the digest says Jeff, never Speaker 1; '
      'the stored transcript keeps its raw labels', (tester) async {
    final live = await mount(
      tester,
      'regen-named',
      installed: false,
      speakerNames: '{"Speaker 1":"Jeff","Speaker 2":"Ana"}',
    );

    await pressAndWait(
      tester,
      'regen-named',
      () => find
          .byKey(const ValueKey('notes-regenerated-snack'))
          .evaluate()
          .isNotEmpty,
    );

    final DumpRow? after = await tester.runAsync<DumpRow?>(
      () => live.db.getDump('regen-named'),
    );
    final String notes = after!.meetingNotes!;
    expect(notes, contains('Jeff'));
    expect(notes, contains('Ana'));
    expect(notes, isNot(contains('Speaker 1')));
    expect(notes, isNot(contains('Speaker 2')));
    expect(
      after.transcript,
      _rawTranscript,
      reason: 'rendering is for the digest only; the store stays raw',
    );
    expect(after.speakerNames, '{"Speaker 1":"Jeff","Speaker 2":"Ana"}');
    // The public sidecar carries the same named digest and the raw text.
    final String sidecar = (await tester.runAsync(
      () => live.storage.metaPathFor('regen-named').readAsString(),
    ))!;
    final Map<String, dynamic> metadata =
        jsonDecode(sidecar) as Map<String, dynamic>;
    expect(metadata['meetingNotes'], contains('Jeff'));
    expect(metadata['meetingNotes'], isNot(contains('Speaker 1')));
    expect(metadata['transcript'], _rawTranscript);
    await unmount(tester);
  });

  testWidgets('L3: empty map → the digest keeps the raw labels',
      (tester) async {
    final live = await mount(tester, 'regen-unnamed', installed: false);

    await pressAndWait(
      tester,
      'regen-unnamed',
      () => find
          .byKey(const ValueKey('notes-regenerated-snack'))
          .evaluate()
          .isNotEmpty,
    );

    final DumpRow? after = await tester.runAsync<DumpRow?>(
      () => live.db.getDump('regen-unnamed'),
    );
    final String notes = after!.meetingNotes!;
    expect(notes, contains('Speaker 1'));
    expect(notes, isNot(contains('Jeff')));
    expect(after.transcript, _rawTranscript);
    await unmount(tester);
  });
}

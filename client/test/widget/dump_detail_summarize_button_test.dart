// SPDX-License-Identifier: AGPL-3.0-or-later
/// Arc B (summary templates): the dump detail's Summarize / Summarize again
/// button. It lives in the AI-summary slot, needs a transcript and the
/// capability switched on, opens the shared template picker, POSTs the
/// pick — and PRESERVES the old summary until the new one arrives via sync.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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
import 'package:tangent/services/summary_pending.dart';

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

const SummaryTemplates _catalogue = SummaryTemplates(
  templates: <SummaryTemplate>[
    SummaryTemplate(id: 'meeting', displayName: 'Meeting'),
    SummaryTemplate(id: 'brain_dump', displayName: 'Brain dump'),
    SummaryTemplate(id: 'lecture', displayName: 'Lecture'),
    SummaryTemplate(id: 'actions_only', displayName: 'Actions only'),
  ],
  customConfigured: false,
);

class _FakeSummariesClient extends SummariesClient {
  _FakeSummariesClient() : super(baseUrl: 'http://unused.invalid');

  final List<(String, String?)> summarizeCalls = <(String, String?)>[];

  @override
  Future<SummaryTemplates> listTemplates() async => _catalogue;

  @override
  Future<void> summarizeDump(String dumpId, {String? template}) async {
    summarizeCalls.add((dumpId, template));
  }
}

const String _summaryMarkdown = '## Summary\n'
    'Team discussed the roadmap and agreed to ship the beta.\n'
    '\n'
    '## Action items\n'
    '- Alice: prepare the release notes';

void main() {
  void useTallViewport(WidgetTester tester) {
    // Tall enough that the bottom-sheet rows never need scrolling (a drag
    // would dismiss the sheet) and the summary slot is on screen.
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  DumpRow meetingRow(
    AudioStorage storage,
    String id, {
    String? summary,
    String? transcript = '[00:00] Alice: hello and welcome to planning',
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
        transcriptionStatus:
            transcript == null ? 'not_transcribed' : 'completed',
        transcriptionAttempt: transcript == null ? 0 : 1,
        transcript: transcript,
        summary: summary,
        summaryModel: summary == null ? null : 'Qwen3-4B-Instruct-2507-Q4_K_M',
        summarizedAt: summary == null ? null : 1790000000,
      );

  Future<_FakeSummariesClient> mountDetail(
    WidgetTester tester,
    DumpRow row, {
    bool capability = true,
  }) async {
    final temp = createResolvedTempSync('tangent-summarize-btn-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final client = _FakeSummariesClient();
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
          summariesEnabledProvider.overrideWith((ref) => capability),
          summariesClientProvider.overrideWith(
            (ref) => Future<SummariesClient>.value(client),
          ),
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
    return client;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Finder button(String id) => find.byKey(ValueKey('summarize-again-$id'));

  testWidgets(
      'with a summary the button reads "Summarize again" and sits in '
      'the AI summary block', (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-again-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(
      tester,
      meetingRow(storage, 'btn-1', summary: _summaryMarkdown),
    );

    expect(button('btn-1'), findsOneWidget);
    expect(
      find.descendant(
        of: button('btn-1'),
        matching: find.text('Summarize again'),
      ),
      findsOneWidget,
    );
    final double headerY = tester
        .getTopLeft(find.byKey(const ValueKey('ai-summary-header-btn-1')))
        .dy;
    final double buttonY = tester.getTopLeft(button('btn-1')).dy;
    expect(
      buttonY,
      greaterThan(headerY),
      reason: 'the button belongs to the summary block, below its header',
    );
    await unmount(tester);
  });

  testWidgets('with a transcript but no summary the button reads "Summarize"',
      (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-first-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(tester, meetingRow(storage, 'btn-2', summary: null));

    expect(button('btn-2'), findsOneWidget);
    expect(
      find.descendant(of: button('btn-2'), matching: find.text('Summarize')),
      findsOneWidget,
    );
    expect(find.text('Summarize again'), findsNothing);
    expect(find.byKey(const ValueKey('ai-summary-header-btn-2')), findsNothing);
    await unmount(tester);
  });

  testWidgets('absent with a blank transcript', (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-blank-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(tester, meetingRow(storage, 'btn-3', transcript: '   '));

    expect(
      button('btn-3'),
      findsNothing,
      reason: 'nothing to summarize — the button can never apply here',
    );
    await unmount(tester);
  });

  testWidgets('absent while the AI-summaries capability is off',
      (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-off-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    await mountDetail(
      tester,
      meetingRow(storage, 'btn-4', summary: _summaryMarkdown),
      capability: false,
    );

    expect(
      button('btn-4'),
      findsNothing,
      reason: 'while AI summaries are off, none of their UI appears',
    );
    // The synced summary itself still renders: it is data, not a feature UI.
    expect(find.byKey(const ValueKey('ai-summary-body-btn-4')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
      'tapping opens the picker; picking Lecture POSTs template=lecture and '
      'the OLD summary body stays on screen (preserve-until-success)',
      (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-preserve-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final client = await mountDetail(
      tester,
      meetingRow(storage, 'btn-5', summary: _summaryMarkdown),
    );

    await tester.tap(button('btn-5'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('summary-template-sheet')),
      findsOneWidget,
      reason: 'the button must open the shared template picker',
    );
    expect(
      client.summarizeCalls,
      isEmpty,
      reason: 'nothing is posted until a template is picked',
    );
    // The dump's effective template is marked as current.
    expect(
      find.byKey(const ValueKey<String>('summary-template-current-meeting')),
      findsOneWidget,
    );

    await tester
        .tap(find.byKey(const ValueKey<String>('summary-template-lecture')));
    await tester.pumpAndSettle();

    expect(client.summarizeCalls, <(String, String?)>[('btn-5', 'lecture')]);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Summary queued'),
      ),
      findsOneWidget,
    );
    // Preserve-until-success: the old summary is still there, verbatim.
    final Finder body = find.byKey(const ValueKey('ai-summary-body-btn-5'));
    expect(
      body,
      findsOneWidget,
      reason: 'queueing a new summary must not hide the old one',
    );
    expect(
      tester.widget<MarkdownBody>(body).data,
      contains('Team discussed the roadmap'),
      reason: 'the old text stays until sync delivers the replacement',
    );
    expect(
      find.byKey(const ValueKey('ai-summary-header-btn-5')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets(
      'the pick sticks: reopening the picker straight after a 202 marks the '
      'NEW template as current, before the summary has synced down',
      (tester) async {
    // Jeff, 2026-09-26: tapped Lecture, reopened Summarize immediately and
    // saw Meeting still ticked. The picker reads the local row's
    // summary_template, which only the finished summary's sync used to
    // update — 30-60 s later. The 202 must mirror the choice locally.
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-sticks-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final client = _FakeSummariesClient();
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
    });
    final row = meetingRow(storage, 'btn-6', summary: _summaryMarkdown);
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          // The REAL row stream: the whole point is what the row says.
          dumpByIdProvider(row.id).overrideWith(
            (ref) => db.watchDump(row.id),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
          summariesEnabledProvider.overrideWith((ref) => true),
          summariesClientProvider.overrideWith(
            (ref) => Future<SummariesClient>.value(client),
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
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

    await tester.tap(button('btn-6'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('summary-template-current-meeting')),
      findsOneWidget,
    );
    // v1.18.0: the 202 also starts the "summary in progress" strip, whose
    // bar and ticker never settle — bounded pumps from here on.
    await tester
        .tap(find.byKey(const ValueKey<String>('summary-template-lecture')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(client.summarizeCalls, <(String, String?)>[('btn-6', 'lecture')]);

    // Straight away — no sync has happened, no summary has arrived.
    final DumpRow? after = await db.getDump('btn-6');
    expect(after?.summaryTemplate, 'lecture',
          reason: 'the accepted pick is mirrored into the local row',
    );
    expect(after?.syncDirty ?? false, isFalse,
          reason: 'the server already holds it; no push must race the worker',
    );
    expect(after?.summary, _summaryMarkdown,
          reason: 'preserve-until-success: the old summary is untouched',
    );

    // While the server works the button is disabled (one job per dump), so
    // "reopen straight away" here means: nothing synced, the request simply
    // aged past the ten-minute give-up. The row is untouched either way.
    final DateTime start = DateTime.now();
    summaryPendingClock = () => start.add(const Duration(minutes: 11));
    addTearDown(() => summaryPendingClock = DateTime.now);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(button('btn-6'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('summary-template-current-lecture')),
      findsOneWidget,
      reason: 'reopened immediately, the picker shows the NEW pick as current',
    );
    expect(
      find.byKey(const ValueKey<String>('summary-template-current-meeting')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('summary-template-lecture')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await unmount(tester);
  });

  testWidgets(
      'summary in progress: after a 202 the pending card sits above the OLD '
      'summary, the button disables, and the server answer clears it all',
      (tester) async {
    // Jeff, 2026-09-26: "there needs to be a loading bar of sorts that
    // replaces the AI Summary area while it's being worked on by the
    // server. its too ambiguous right now when it's thinking". The 202
    // stamps summary_requested_at; the finished summary's sync (a newer
    // summarized_at) clears it. Preserve-until-success throughout.
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-pending-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final client = _FakeSummariesClient();
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
    });
    final row = meetingRow(storage, 'btn-7', summary: _summaryMarkdown);
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          // The REAL row stream: the card must come and go with the row.
          dumpByIdProvider(row.id).overrideWith(
            (ref) => db.watchDump(row.id),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
          summariesEnabledProvider.overrideWith((ref) => true),
          summariesClientProvider.overrideWith(
            (ref) => Future<SummariesClient>.value(client),
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
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

    final Finder card =
        find.byKey(const ValueKey<String>('ai-summary-pending-btn-7'));
    final Finder body =
        find.byKey(const ValueKey<String>('ai-summary-body-btn-7'));
    expect(card, findsNothing, reason: 'nothing requested yet');
    expect(
      tester.widget<FilledButton>(button('btn-7')).onPressed,
      isNotNull,
    );

    await tester.tap(button('btn-7'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('summary-template-lecture')));
    // Bounded pumps from here on: the card's bar and ticker never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(client.summarizeCalls, <(String, String?)>[('btn-7', 'lecture')]);

    expect(card, findsOneWidget, reason: 'the 202 shows work in progress');
    expect(
      find.descendant(of: card, matching: find.byType(LinearProgressIndicator)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('Writing Lecture summary on your server…'),
      ),
      findsOneWidget,
      reason: 'names the template the server is writing',
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('the current summary stays'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('ai-summary-header-btn-7')),
      findsOneWidget,
      reason: 'the header is unchanged',
    );
    expect(body, findsOneWidget, reason: 'preserve-until-success');
    expect(tester.widget<MarkdownBody>(body).data, _summaryMarkdown);
    final FilledButton disabled = tester.widget<FilledButton>(button('btn-7'));
    expect(disabled.onPressed, isNull, reason: 'one job per dump: no re-tap');
    expect(
      find.descendant(of: button('btn-7'), matching: find.text('Summarizing…')),
      findsOneWidget,
    );

    // The ticker moves once a second, driven by a periodic timer. The
    // test binding's fake clock does not move DateTime.now, so the rule's
    // clock is driven explicitly alongside the pumps.
    final Finder elapsed = find.byKey(
      const ValueKey<String>('ai-summary-pending-elapsed-btn-7'),
    );
    // Anchor on the row's OWN requested-at second, not DateTime.now(): the
    // 202 stamped whole seconds a moment ago, so 'now + 42 s' straddles a
    // tick boundary under load and read 0:43 in a full-suite run.
    final int requestedAt =
        (await db.getDump('btn-7'))!.summaryRequestedAt!;
    final DateTime start =
        DateTime.fromMillisecondsSinceEpoch(requestedAt * 1000, isUtc: true);
    addTearDown(() => summaryPendingClock = DateTime.now);
    expect(tester.widget<Text>(elapsed).data, startsWith('Elapsed 0:0'));
    summaryPendingClock = () => start.add(const Duration(seconds: 42));
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<Text>(elapsed).data,
      'Elapsed 0:42 · the current summary stays until the new one arrives',
      reason: 'the periodic timer re-reads the clock every second',
    );
    summaryPendingClock = () => start.add(const Duration(seconds: 75));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(elapsed).data, startsWith('Elapsed 1:15'));
    summaryPendingClock = DateTime.now;

    // The server answers: a newer summarized_at arrives via sync apply.
    final DumpRow pendingRow = (await db.getDump('btn-7'))!;
    expect(pendingRow.summaryRequestedAt, isNotNull);
    await db.applyRemoteDump(
      id: 'btn-7',
      mode: 'meeting',
      title: row.title,
      transcript: row.transcript,
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      seq: 12,
      summary: '## Summary\nThe NEW lecture summary.',
      summaryModel: 'Qwen3-4B-Instruct-2507-Q4_K_M',
      summarizedAt: pendingRow.summaryRequestedAt! + 60,
      summaryTemplate: 'lecture',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(card, findsNothing, reason: 'the answer landed: no more strip');
    expect(
      tester.widget<MarkdownBody>(body).data,
      '## Summary\nThe NEW lecture summary.',
    );
    expect(
      tester.widget<FilledButton>(button('btn-7')).onPressed,
      isNotNull,
      reason: 're-enabled from the row stream, no polling',
    );
    expect(
      find.descendant(
        of: button('btn-7'),
        matching: find.text('Summarize again'),
      ),
      findsOneWidget,
    );
    expect(
      (await db.getDump('btn-7'))!.summaryRequestedAt,
      isNull,
      reason: 'the marker is spent the moment the answer lands',
    );

    // A later change that carries an OLDER summarized_at (a peer's stale
    // echo of the previous summary) must NOT bring the strip back: the
    // request was answered and the marker is gone, not merely outranked.
    await db.applyRemoteDump(
      id: 'btn-7',
      mode: 'meeting',
      title: 'Sprint planning (renamed on the tablet)',
      transcript: row.transcript,
      meetingNotes: null,
      durationSeconds: 4,
      audioOnServer: true,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      seq: 13,
      summary: _summaryMarkdown,
      summaryModel: 'Qwen3-4B-Instruct-2507-Q4_K_M',
      summarizedAt: pendingRow.summaryRequestedAt! - 100,
      summaryTemplate: 'meeting',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing, reason: 'a stale echo never revives the strip');
    expect(
      tester.widget<FilledButton>(button('btn-7')).onPressed,
      isNotNull,
    );
    await unmount(tester);
  });
  /// v1.19.0 harness: a REAL row stream (db.watchDump) so server publishes
  /// applied through applyRemoteDump reach the screen, plus a recorded
  /// summaries client. Returns the db/client pair the test drives.
  Future<({LocalDb db, _FakeSummariesClient client, DumpRow row})> mountLive(
    WidgetTester tester,
    AudioStorage storage,
    String id, {
    String? summary,
  }) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final client = _FakeSummariesClient();
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
    });
    final row = meetingRow(storage, id, summary: summary);
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          dumpByIdProvider(row.id).overrideWith(
            (ref) => db.watchDump(row.id),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
          summariesEnabledProvider.overrideWith((ref) => true),
          summariesClientProvider.overrideWith(
            (ref) => Future<SummariesClient>.value(client),
          ),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
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
    return (db: db, client: client, row: row);
  }

  /// A server publish for [row] carrying the summary verdict (v1.19.0:
  /// `summary_status` is always present on the wire; null = idle/done).
  Future<void> publish(
    LocalDb db,
    DumpRow row, {
    required int seq,
    required String? summary,
    required int? summarizedAt,
    required String? summaryStatus,
    String? summaryError,
    int? summaryQueuePosition,
  }) =>
      db.applyRemoteDump(
        id: row.id,
        mode: 'meeting',
        title: row.title,
        transcript: row.transcript,
        meetingNotes: null,
        durationSeconds: 4,
        audioOnServer: true,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        seq: seq,
        summary: summary,
        summaryModel:
            summary == null ? null : 'Qwen3-4B-Instruct-2507-Q4_K_M',
        summarizedAt: summarizedAt,
        summaryTemplate: summary == null ? null : 'meeting',
        summaryStatus: summaryStatus,
        summaryError: summaryError,
        summaryQueuePosition: summaryQueuePosition,
      );

  testWidgets(
      'summary failed (v1.19.0): the pulled failure shows the red line over '
      'the OLD summary with the button enabled; Retry re-posts the row\'s '
      'template without the picker; dismiss hides the line locally; the '
      'pulled success clears both the line and the dismissal',
      (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-failed-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final live = await mountLive(
      tester,
      storage,
      'btn-8',
      summary: _summaryMarkdown,
    );
    final LocalDb db = live.db;
    final DumpRow row = live.row;
    final int before = row.summarizedAt!;

    final Finder failed =
        find.byKey(const ValueKey<String>('ai-summary-failed-btn-8'));
    final Finder card =
        find.byKey(const ValueKey<String>('ai-summary-pending-btn-8'));
    final Finder body =
        find.byKey(const ValueKey<String>('ai-summary-body-btn-8'));
    expect(failed, findsNothing, reason: 'nothing failed yet');

    // (a) The server reports the last attempt failed. The old summary
    // echoes back unchanged with the verdict on it.
    await publish(
      db,
      row,
      seq: 20,
      summary: _summaryMarkdown,
      summarizedAt: before,
      summaryStatus: 'failed',
      summaryError: 'RuntimeError: model missing',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(failed, findsOneWidget, reason: 'the red line replaces the card');
    expect(
      find.descendant(
        of: failed,
        matching: find.text('Summary failed: RuntimeError: model missing'),
      ),
      findsOneWidget,
    );
    expect(card, findsNothing, reason: 'failed is never "in progress"');
    expect(body, findsOneWidget, reason: 'the old body stays underneath');
    expect(tester.widget<MarkdownBody>(body).data, _summaryMarkdown);
    expect(
      tester.widget<FilledButton>(button('btn-8')).onPressed,
      isNotNull,
      reason: 'a failure is a terminal state: the button is live again',
    );

    // Retry: the row's CURRENT effective template (meeting), no picker.
    await tester.tap(find.byKey(const ValueKey<String>('summary-retry-btn-8')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey<String>('summary-template-sheet')),
      findsNothing,
      reason: 'Retry re-runs the last choice; it never asks again',
    );
    expect(
      live.client.summarizeCalls,
      <(String, String?)>[('btn-8', 'meeting')],
    );
    // The 202 stamped a fresh request: the strip is back, the line gone.
    expect(card, findsOneWidget, reason: 'a retry is a request in progress');
    expect(failed, findsNothing);
    expect((await db.getDump('btn-8'))!.summaryRequestedAt, isNotNull);

    // (b) The retry fails as well. The local marker is spent by the
    // verdict, and the user dismisses the line on this device.
    await publish(
      db,
      row,
      seq: 21,
      summary: _summaryMarkdown,
      summarizedAt: before,
      summaryStatus: 'failed',
      summaryError: 'RuntimeError: model missing',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing, reason: 'the verdict outranks the local guess');
    expect(failed, findsOneWidget);
    expect((await db.getDump('btn-8'))!.summaryRequestedAt, isNull);

    await tester
        .tap(find.byKey(const ValueKey<String>('summary-dismiss-btn-8')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(failed, findsNothing, reason: 'dismissed on this device');
    expect(body, findsOneWidget, reason: 'the old body is untouched');
    final DumpRow dismissed = (await db.getDump('btn-8'))!;
    expect(dismissed.summaryErrorDismissedAt, isNotNull);
    expect(dismissed.summaryStatus, 'failed', reason: 'the verdict stays');
    expect(
      tester.widget<FilledButton>(button('btn-8')).onPressed,
      isNotNull,
    );

    // (c) A later attempt succeeds: status null, summarized_at advances.
    await publish(
      db,
      row,
      seq: 22,
      summary: '## Summary\nThe NEW summary after the fix.',
      summarizedAt: before + 600,
      summaryStatus: null,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(failed, findsNothing);
    expect(card, findsNothing);
    expect(
      tester.widget<MarkdownBody>(body).data,
      '## Summary\nThe NEW summary after the fix.',
    );
    final DumpRow succeeded = (await db.getDump('btn-8'))!;
    expect(
      succeeded.summaryErrorDismissedAt,
      isNull,
      reason: 'success spends the dismissal: the next failure must show',
    );
    expect(succeeded.summaryStatus, isNull);

    // ...and the next failure does show, with no dismiss in the way.
    await publish(
      db,
      row,
      seq: 23,
      summary: '## Summary\nThe NEW summary after the fix.',
      summarizedAt: before + 600,
      summaryStatus: 'failed',
      summaryError: 'timeout',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(failed, findsOneWidget, reason: 'a fresh failure is never hidden');
    expect(
      find.descendant(
        of: failed,
        matching: find.text('Summary failed: timeout'),
      ),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets(
      'summary failed with NO prior summary: the red line takes the slot and '
      'the plain Summarize button stays enabled below it', (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-failed-first-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final live = await mountLive(tester, storage, 'btn-9', summary: null);

    await publish(
      live.db,
      live.row,
      seq: 20,
      summary: null,
      summarizedAt: null,
      summaryStatus: 'failed',
      summaryError: 'RuntimeError: model missing',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final Finder failed =
        find.byKey(const ValueKey<String>('ai-summary-failed-btn-9'));
    expect(failed, findsOneWidget);
    expect(find.byKey(const ValueKey('ai-summary-body-btn-9')), findsNothing);
    expect(find.byKey(const ValueKey('ai-summary-header-btn-9')), findsNothing);
    expect(
      tester.widget<FilledButton>(button('btn-9')).onPressed,
      isNotNull,
    );
    expect(
      find.descendant(of: button('btn-9'), matching: find.text('Summarize')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets(
      'server-reported queue position names the place in line; running '
      'keeps the Writing line (v1.19.0)', (tester) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-btn-queued-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AudioStorage.test(temp);
    final live = await mountLive(
      tester,
      storage,
      'btn-10',
      summary: _summaryMarkdown,
    );
    final int before = live.row.summarizedAt!;
    final Finder card =
        find.byKey(const ValueKey<String>('ai-summary-pending-btn-10'));
    final Finder headline = find.byKey(
      const ValueKey<String>('ai-summary-pending-headline-btn-10'),
    );

    // Queued, 2nd in line — a job another device requested: no local
    // request time, so the card carries no elapsed counter either.
    await publish(
      live.db,
      live.row,
      seq: 20,
      summary: _summaryMarkdown,
      summarizedAt: before,
      summaryStatus: 'queued',
      summaryQueuePosition: 2,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsOneWidget, reason: 'queued on the server is pending');
    expect(tester.widget<Text>(headline).data, 'Queued — 2nd in line');
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey<String>('ai-summary-pending-elapsed-btn-10'),
            ),
          )
          .data,
      'The current summary stays until the new one arrives',
    );
    expect(
      tester.widget<FilledButton>(button('btn-10')).onPressed,
      isNull,
      reason: 'one job per dump, whoever asked',
    );
    expect(
      find.byKey(const ValueKey<String>('ai-summary-failed-btn-10')),
      findsNothing,
    );

    // Running: the position is gone, the writing line names the template.
    await publish(
      live.db,
      live.row,
      seq: 21,
      summary: _summaryMarkdown,
      summarizedAt: before,
      summaryStatus: 'running',
      summaryQueuePosition: null,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsOneWidget);
    expect(tester.widget<Text>(headline).data, contains('Writing'));
    expect(tester.widget<Text>(headline).data, contains('Meeting'));

    // A server 'running' never expires client-side: ten minutes on, with
    // no local request to give up on, the card still stands.
    final DateTime start =
        DateTime.fromMillisecondsSinceEpoch(before * 1000, isUtc: true);
    addTearDown(() => summaryPendingClock = DateTime.now);
    summaryPendingClock = () => start.add(const Duration(minutes: 11));
    await tester.pump(const Duration(minutes: 11));
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsOneWidget, reason: 'the server publishes the outcome');
    summaryPendingClock = DateTime.now;

    // The outcome: idle with a newer summary clears the card.
    await publish(
      live.db,
      live.row,
      seq: 22,
      summary: '## Summary\nDone.',
      summarizedAt: before + 60,
      summaryStatus: null,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(
      tester.widget<FilledButton>(button('btn-10')).onPressed,
      isNotNull,
    );
    await unmount(tester);
  });
}

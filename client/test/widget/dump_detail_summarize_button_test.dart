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
}

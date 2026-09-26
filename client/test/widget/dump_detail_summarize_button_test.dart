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
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// Speaker naming (v1.15.0 spec §4.2 / §5) on the dump detail screen:
/// the app-bar overflow (`detail-more`) offers "Name speakers" only when the
/// transcript has speaker headings (since v1.16.0 the overflow also carries
/// "Export Markdown", so the BUTTON stays while the ENTRY goes — see
/// dump_detail_export_markdown_test.dart for the button's own gate); since
/// v1.17.0 names live in the per-recording map, so the "Overwrite
/// transcript?" dialog never warns about losing them, the editor shows the
/// RENDERED transcript, and Save reverses the map before persisting.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/models/speaker_names.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/settings/ai_summaries_section.dart';
import 'package:tangent/services/recording_playback.dart';

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

/// Straight from the formatter: raw labels only.
const String _rawSpeakers = '## Speaker 1\n'
    'Ended up getting fired and then hired again.\n'
    '\n'
    '## Speaker 2\n'
    'That is quite the arc.\n';

/// After a rename: one user-given name, one raw label left.
const String _namedSpeakers = '## Alice\n'
    'Ended up getting fired and then hired again.\n'
    '\n'
    '## Speaker 2\n'
    'That is quite the arc.\n';

const String _plain = '[00:00] Alice: hello and welcome to planning';

const String _warning = 'Speaker names you added will be reset.';

void main() {
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  DumpRow meetingRow(
    AudioStorage storage,
    String id,
    String transcript, {
    String? speakerNames,
  }) =>
      DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 26),
        updatedAt: DateTime.utc(2026, 9, 26),
        mode: 'meeting',
        durationSeconds: 4,
        title: 'Sprint planning',
        audioPath: storage.pathFor(id).path,
        audioSizeBytes: 3,
        syncStatus: 'synced',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionAttempt: 1,
        transcript: transcript,
        speakerNames: speakerNames,
      );

  late LocalDb db;

  Future<void> mountDetail(
    WidgetTester tester,
    String id,
    String transcript, {
    String? speakerNames,
  }) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-speakers-detail-');
    db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final seeded = meetingRow(storage, id, transcript, speakerNames: speakerNames);
    await seedFileFixtureRow(db, seeded);
    storage.pathFor(id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          dumpByIdProvider(id).overrideWith(
            (ref) => Stream<DumpRow?>.value(seeded),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
          summariesEnabledProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: id,
            audioPath: seeded.audioPath,
            durationSeconds: seeded.durationSeconds,
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

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  final Finder more = find.byKey(const ValueKey('detail-more'));

  testWidgets('diarized transcript: detail-more overflow opens the sheet',
      (tester) async {
    await mountDetail(tester, 'spk-1', _rawSpeakers);

    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Name speakers'), findsOneWidget);

    await tester.tap(find.text('Name speakers'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('name-speakers-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('speaker-name-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('speakers-cancel')));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('no speaker headings: the Name speakers entry is absent',
      (tester) async {
    await mountDetail(tester, 'spk-2', _plain);

    expect(
      find.byIcon(Icons.delete_outline),
      findsOneWidget,
      reason: 'the existing icon row is untouched',
    );
    // v1.16.0: the overflow still exists for Export Markdown (the plain
    // transcript IS exportable), but the naming entry must not be offered —
    // absent, not disabled.
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-name-speakers')), findsNothing);
    expect(find.text('Name speakers'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('re-transcribe never warns about names, even when the map '
      'has them (N2=y: names survive in the map)', (tester) async {
    await mountDetail(
      tester,
      'spk-3',
      _rawSpeakers,
      speakerNames: '{"Speaker 1":"Alice"}',
    );

    await tester.tap(find.byKey(const ValueKey('transcribe-spk-3')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsOneWidget);
    expect(find.textContaining(_warning), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('re-transcribe with a user heading in the text does not warn '
      'either (the gate is gone)', (tester) async {
    await mountDetail(tester, 'spk-4', _namedSpeakers);

    await tester.tap(find.byKey(const ValueKey('transcribe-spk-4')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsOneWidget);
    expect(find.textContaining(_warning), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('the editor shows the rendered transcript and Save persists '
      'the raw labels (spec §3 Edit mode)', (tester) async {
    await mountDetail(
      tester,
      'spk-5',
      _rawSpeakers,
      speakerNames: '{"Speaker 1":"Jeff"}',
    );
    // Option B: meeting transcripts start collapsed — expand before editing.
    await tester.tap(find.byKey(const ValueKey('transcript-header-spk-5')));
    await tester.pumpAndSettle();

    final Finder editor = find.byKey(const ValueKey('transcript-editor-spk-5'));
    final String shown = tester.widget<TextField>(editor).controller!.text;
    expect(shown, startsWith('## Jeff\n'));
    expect(shown, contains('## Speaker 2\n'), reason: 'unmapped label as is');
    expect(shown, isNot(contains('## Speaker 1')));
    final Finder save = find.byKey(const ValueKey('save-transcript-spk-5'));
    expect(
      tester.widget<FilledButton>(save).onPressed,
      isNull,
      reason: 'rendered text is not a dirty edit',
    );

    // Edit prose only; the heading the user sees stays `## Jeff`.
    final String edited = shown.replaceFirst('hired again', 'hired back');
    await tester.enterText(editor, edited);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(save).onPressed!();
    });
    await pumpBoundUntil(
      tester,
      () async => (await db.getDump('spk-5'))!.transcript!.contains('hired back'),
    );
    // One frame, not pumpAndSettle: the sidecar publication may still be
    // spinning under suite load, and the row is already what we assert on.
    await tester.pump();

    final DumpRow saved = (await db.getDump('spk-5'))!;
    expect(saved.transcript, contains('## Speaker 1\n'));
    expect(saved.transcript, isNot(contains('## Jeff')));
    expect(saved.transcript, contains('hired back'));
    expect(
      SpeakerNames.decode(saved.speakerNames).nameFor('Speaker 1'),
      'Jeff',
      reason: 'the map is untouched by an Edit save',
    );
    await unmount(tester);
  });
}

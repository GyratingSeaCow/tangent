// SPDX-License-Identifier: AGPL-3.0-or-later
/// Speaker naming (v1.15.0 spec §4.2 / §5) on the dump detail screen:
/// the app-bar overflow (`detail-more`) exists only to hold "Name speakers"
/// and is absent when the transcript has no speakers; and the
/// "Overwrite transcript?" dialog warns that names will be reset only when
/// a user-given speaker name is actually present.
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

  DumpRow meetingRow(AudioStorage storage, String id, String transcript) =>
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
      );

  Future<void> mountDetail(
    WidgetTester tester,
    String id,
    String transcript,
  ) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-speakers-detail-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final seeded = meetingRow(storage, id, transcript);
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

  testWidgets('no speaker headings: the overflow button is absent',
      (tester) async {
    await mountDetail(tester, 'spk-2', _plain);

    expect(more, findsNothing, reason: 'absent, not disabled');
    expect(
      find.byIcon(Icons.delete_outline),
      findsOneWidget,
      reason: 'the existing icon row is untouched',
    );
    await unmount(tester);
  });

  testWidgets('re-transcribe warns about names only once a speaker is named',
      (tester) async {
    await mountDetail(tester, 'spk-3', _namedSpeakers);

    await tester.tap(find.byKey(const ValueKey('transcribe-spk-3')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsOneWidget);
    expect(find.textContaining(_warning), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('re-transcribe with only raw Speaker N labels does not warn',
      (tester) async {
    await mountDetail(tester, 'spk-4', _rawSpeakers);

    await tester.tap(find.byKey(const ValueKey('transcribe-spk-4')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsOneWidget);
    expect(
      find.textContaining(_warning),
      findsNothing,
      reason: 'nothing user-given to lose',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });
}

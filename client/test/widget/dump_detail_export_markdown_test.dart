// SPDX-License-Identifier: AGPL-3.0-or-later
/// Timestamped Markdown export (v1.16.0 spec §4) on the dump detail screen:
/// the app-bar overflow (`detail-more`, added in v1.15.0 for "Name speakers")
/// now also carries "Export Markdown" (`detail-export-markdown`). Both entries
/// show when both apply, only the export shows on a plain transcript, and the
/// button is still absent when there is nothing to export or name. Picking
/// the export calls the one export provider with the current row.
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
import 'package:tangent/services/markdown_export.dart';
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

const String _plain = '[00:00] Alice: hello and welcome to planning';

void main() {
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  DumpRow meetingRow(AudioStorage storage, String id, String? transcript) =>
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
    String? transcript, {
    List<Override> extraOverrides = const <Override>[],
  }) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-md-detail-');
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
          ...extraOverrides,
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
  final Finder nameEntry = find.byKey(const ValueKey('detail-name-speakers'));
  final Finder exportEntry =
      find.byKey(const ValueKey('detail-export-markdown'));

  testWidgets('diarized transcript: detail-more carries BOTH entries',
      (tester) async {
    await mountDetail(tester, 'md-1', _rawSpeakers);

    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(nameEntry, findsOneWidget);
    expect(exportEntry, findsOneWidget);
    expect(find.text('Name speakers'), findsOneWidget);
    expect(find.text('Export Markdown'), findsOneWidget);
    expect(
      tester.getTopLeft(exportEntry).dy,
      greaterThan(tester.getTopLeft(nameEntry).dy),
      reason: 'Name speakers stays first; the export is the second entry',
    );

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('plain transcript: the overflow shows only Export Markdown',
      (tester) async {
    await mountDetail(tester, 'md-2', _plain);

    expect(
      more,
      findsOneWidget,
      reason: 'the button now shows when EITHER entry applies',
    );
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(exportEntry, findsOneWidget);
    expect(nameEntry, findsNothing, reason: 'nothing to name');

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('no transcript: the overflow button is absent', (tester) async {
    await mountDetail(tester, 'md-3', null);

    expect(more, findsNothing, reason: 'absent, not disabled');
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('picking Export Markdown calls the provider with the row',
      (tester) async {
    final List<DumpRow> exported = <DumpRow>[];
    await mountDetail(
      tester,
      'md-4',
      _plain,
      extraOverrides: <Override>[
        exportMarkdownProvider.overrideWithValue((DumpRow row) async {
          exported.add(row);
          return const MarkdownExportOutcome(
            path: '/exports/md-4.md',
            opened: false,
          );
        }),
      ],
    );

    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(exportEntry);
    await tester.pumpAndSettle();

    expect(exported.map((r) => r.id), ['md-4']);
    expect(exported.single.transcript, _plain);
    expect(
      find.text('Exported to /exports/md-4.md (no Markdown handler)'),
      findsOneWidget,
      reason: 'a viewer-less desktop still learns where the file landed',
    );
    await unmount(tester);
  });
}

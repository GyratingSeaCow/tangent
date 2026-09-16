// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/bound_row_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;

DumpRow _row(
  String id, {
  String title = 'T',
  String transcript = '',
  String mode = 'brain_dump',
  SyncStatus status = SyncStatus.pending,
  String? transcriptionStatus,
}) {
  return DumpRow(
    id: id,
    createdAt:
        DateTime.utc(2026, 1, 1).add(Duration(seconds: int.tryParse(id) ?? 0)),
    updatedAt: DateTime.utc(2026, 1, 1),
    mode: mode,
    durationSeconds: 5,
    title: title,
    transcript: transcript,
    audioPath: '/tmp/$id.opus',
    audioSizeBytes: 100,
    syncStatus: status.wireValue,
    syncAttempts: 0,
    transcriptionStatus: transcriptionStatus ??
        (transcript.trim().isEmpty ? 'not_transcribed' : 'completed'),
    transcriptionAttempt: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dumpsProvider', () {
    test('emits dumps from local DB', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await seedFileFixtureRow(db, _row('1', title: 'First'));
      await seedFileFixtureRow(db, _row('2', title: 'Second'));

      final container = ProviderContainer(
        overrides: [
          localDbProvider.overrideWithValue(db),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final dumps = await container.read(dumpsProvider.future);
      expect(dumps.length, 2);
      expect(dumps.first.title, 'Second'); // newest first
    });

    test('re-emits when a new dump is inserted', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());

      final container = ProviderContainer(
        overrides: [
          localDbProvider.overrideWithValue(db),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      // First read.
      var dumps = await container.read(dumpsProvider.future);
      expect(dumps, isEmpty);

      // Insert and wait for stream to emit.
      await seedFileFixtureRow(db, _row('1', title: 'A new dump'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      dumps = await container.read(dumpsProvider.future);
      expect(dumps.length, 1);
      expect(dumps.first.title, 'A new dump');
    });
  });

  group('searchResultsProvider', () {
    test('empty query returns empty list', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await seedFileFixtureRow(
        db,
        _row('1', title: 'Hello', transcript: 'world'),
      );

      final container = ProviderContainer(
        overrides: [
          localDbProvider.overrideWithValue(db),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      container.read(searchQueryProvider.notifier).state = '   ';
      final results = await container.read(searchResultsProvider.future);
      expect(results, isEmpty);
    });

    test('searches title and transcript via FTS5', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await seedFileFixtureRow(
        db,
        _row('1', title: 'Grocery list', transcript: 'milk eggs'),
      );
      await seedFileFixtureRow(
        db,
        _row('2', title: 'Meeting notes', transcript: 'budget'),
      );

      final container = ProviderContainer(
        overrides: [
          localDbProvider.overrideWithValue(db),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      container.read(searchQueryProvider.notifier).state = 'milk';
      final results = await container.read(searchResultsProvider.future);
      expect(results.length, 1);
      expect(results.first.id, '1');
    });
  });

  group('dump filters', () {
    test('mode and transcript filters combine with logical AND', () {
      final rows = [
        _row('meeting-not-transcribed', mode: 'meeting'),
        _row(
          'meeting-completed',
          mode: 'meeting',
          transcript: 'done',
        ),
        _row('brain-not-transcribed'),
        _row('uploading', transcriptionStatus: 'uploading'),
        _row('queued', transcriptionStatus: 'queued'),
        _row('running', transcriptionStatus: 'running'),
        _row('completed', transcript: 'done'),
        _row('failed', transcriptionStatus: 'failed'),
      ];

      expect(
        filterDumps(
          rows,
          DumpModeFilter.meeting,
          TranscriptFilter.needsTranscript,
        ).map((row) => row.id),
        ['meeting-not-transcribed'],
      );
      expect(
        filterDumps(
          rows,
          DumpModeFilter.all,
          TranscriptFilter.inProgress,
        ).map((row) => row.id),
        ['uploading', 'queued', 'running'],
      );
      expect(
        filterDumps(
          rows,
          DumpModeFilter.brainDump,
          TranscriptFilter.transcribed,
        ).map((row) => row.id),
        ['completed'],
      );
      expect(
        filterDumps(
          rows,
          DumpModeFilter.all,
          TranscriptFilter.failed,
        ).map((row) => row.id),
        ['failed'],
      );
    });

    test('search results respect both selected filters', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await seedFileFixtureRow(
        db,
        _row('1', title: 'Budget brain dump', transcript: 'budget'),
      );
      await seedFileFixtureRow(
        db,
        _row(
          '2',
          title: 'Budget meeting',
          transcript: 'budget',
          mode: 'meeting',
        ),
      );
      await seedFileFixtureRow(
        db,
        _row('3', title: 'Budget meeting awaiting', mode: 'meeting'),
      );
      final container = ProviderContainer(
        overrides: [
          localDbProvider.overrideWithValue(db),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      container.read(dumpModeFilterProvider.notifier).state =
          DumpModeFilter.meeting;
      container.read(transcriptFilterProvider.notifier).state =
          TranscriptFilter.needsTranscript;
      container.read(searchQueryProvider.notifier).state = 'budget';

      final results = await container.read(searchResultsProvider.future);
      expect(results.map((row) => row.id), ['3']);
    });

    test('both filter states survive provider listeners navigating away', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(dumpModeFilterProvider.notifier).state =
          DumpModeFilter.meeting;
      container.read(transcriptFilterProvider.notifier).state =
          TranscriptFilter.failed;
      expect(container.read(dumpModeFilterProvider), DumpModeFilter.meeting);
      expect(container.read(transcriptFilterProvider), TranscriptFilter.failed);
    });
  });
}

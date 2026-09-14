// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;

DumpRow _row(String id, {String title = 'T', String transcript = ''}) {
  return DumpRow(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: int.parse(id))),
    updatedAt: DateTime.utc(2026, 1, 1),
    mode: 'brain_dump',
    durationSeconds: 5,
    title: title,
    transcript: transcript,
    audioPath: '/tmp/$id.opus',
    audioSizeBytes: 100,
    syncStatus: SyncStatus.pending.wireValue,
    syncAttempts: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dumpsProvider', () {
    test('emits dumps from local DB', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await db.upsertDump(_row('1', title: 'First'));
      await db.upsertDump(_row('2', title: 'Second'));

      final container = ProviderContainer(overrides: [
        localDbProvider.overrideWithValue(db),
      ],);
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

      final container = ProviderContainer(overrides: [
        localDbProvider.overrideWithValue(db),
      ],);
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      // First read.
      var dumps = await container.read(dumpsProvider.future);
      expect(dumps, isEmpty);

      // Insert and wait for stream to emit.
      await db.upsertDump(_row('1', title: 'A new dump'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      dumps = await container.read(dumpsProvider.future);
      expect(dumps.length, 1);
      expect(dumps.first.title, 'A new dump');
    });
  });

  group('searchResultsProvider', () {
    test('empty query returns empty list', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await db.upsertDump(_row('1', title: 'Hello', transcript: 'world'));

      final container = ProviderContainer(overrides: [
        localDbProvider.overrideWithValue(db),
      ],);
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
      await db.upsertDump(_row('1', title: 'Grocery list', transcript: 'milk eggs'));
      await db.upsertDump(_row('2', title: 'Meeting notes', transcript: 'budget'));

      final container = ProviderContainer(overrides: [
        localDbProvider.overrideWithValue(db),
      ],);
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
}
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

void main() {
  group('LocalDb', () {
    late LocalDb db;

    setUp(() {
      db = LocalDb.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('inserts and retrieves a dump', () async {
      final row = DumpRow(
        id: 'test-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Test',
        audioPath: '/tmp/test.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
        syncAttempts: 0,
      );
      await db.upsertDump(row);

      final fetched = await db.getDump('test-1');
      expect(fetched, isNotNull);
      expect(fetched!.title, 'Test');
      expect(fetched.mode, 'brain_dump');
    });

    test('lists dumps newest first', () async {
      for (var i = 0; i < 3; i++) {
        await db.upsertDump(DumpRow(
          id: 'test-$i',
          createdAt: DateTime.utc(2026, 1, 1 + i),
          updatedAt: DateTime.utc(2026, 1, 1 + i),
          mode: 'brain_dump',
          durationSeconds: 60,
          title: 'Test $i',
          audioPath: '/tmp/$i.opus',
          audioSizeBytes: 1000,
          syncStatus: 'local_only',
        syncAttempts: 0,
        ));
      }
      final list = await db.listDumps();
      expect(list.length, 3);
      expect(list.first.id, 'test-2');
      expect(list.last.id, 'test-0');
    });

    test('searches by title using FTS5', () async {
      await db.upsertDump(DumpRow(
        id: 'test-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Deployment strategy thoughts',
        audioPath: '/tmp/test.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
        syncAttempts: 0,
      ));
      await db.upsertDump(DumpRow(
        id: 'test-2',
        createdAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
        mode: 'brain_dump',
        durationSeconds: 60,
        title: 'Lunch ideas',
        audioPath: '/tmp/test2.opus',
        audioSizeBytes: 1000,
        syncStatus: 'local_only',
        syncAttempts: 0,
      ));

      final results = await db.searchDumps('deployment');
      expect(results.length, 1);
      expect(results.first.id, 'test-1');
    });
  });
}
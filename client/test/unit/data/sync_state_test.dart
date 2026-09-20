// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client-side document sync: dirty tracking, tombstones, and the checkpoint.
///
/// These exercise the real database rather than a mock, because the bugs that
/// matter here are about what survives in storage.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDb db;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertNotebook(
    String id, {
    String title = 'Notes',
    int updatedAt = 1000,
    bool dirty = true,
  }) async {
    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: id,
            title: title,
            createdAt: 500,
            updatedAt: updatedAt,
            docJson: '{"blocks":[]}',
            inkJson: '{"strokes":[]}',
            syncDirty: Value(dirty),
          ),
        );
  }

  group('device identity', () {
    test('the device id is created once and then reused', () async {
      final SyncStateRow first = await db.syncState(newDeviceId: 'device-a');
      final SyncStateRow second = await db.syncState(newDeviceId: 'device-b');

      expect(
        second.deviceId,
        'device-a',
        reason: 'a second call must not mint a new identity',
      );
      expect(first.lastPulledSeq, 0, reason: 'a new device starts from zero');
    });

    test('the checkpoint survives being advanced', () async {
      await db.syncState(newDeviceId: 'device-a');
      await db.recordPullCheckpoint(42);

      final SyncStateRow state = await db.syncState(newDeviceId: 'device-a');
      expect(state.lastPulledSeq, 42);
      expect(state.lastSyncedAt, isNotNull);
    });
  });

  group('dirty tracking', () {
    test('a new notebook starts dirty so it is pushed at least once',
        () async {
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Fresh',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{}',
              inkJson: '{}',
            ),
          );

      final List<NotebookRow> pending = await db.notebooksNeedingPush();
      expect(pending.map((NotebookRow r) => r.id), contains('nb-1'));
    });

    test('a confirmed push clears the flag', () async {
      await insertNotebook('nb-1', updatedAt: 1000);
      await db.markNotebookSynced('nb-1', seq: 7, pushedUpdatedAt: 1000);

      expect(await db.notebooksNeedingPush(), isEmpty);
      final NotebookRow? row = await db.getNotebookRow('nb-1');
      expect(row!.syncedSeq, 7);
    });

    test('an edit made DURING a push is not marked clean', () async {
      // The race that silently loses work: push starts at updated_at=1000,
      // the user edits (updated_at=2000), the push response arrives. Clearing
      // the flag here would strand that newer edit forever.
      await insertNotebook('nb-1', updatedAt: 1000);
      await (db.update(db.notebooks)..where((t) => t.id.equals('nb-1')))
          .write(const NotebooksCompanion(updatedAt: Value(2000)));

      await db.markNotebookSynced('nb-1', seq: 7, pushedUpdatedAt: 1000);

      final List<NotebookRow> pending = await db.notebooksNeedingPush();
      expect(
        pending.map((NotebookRow r) => r.id),
        contains('nb-1'),
        reason: 'the newer edit must still be waiting to push',
      );
    });

    test('content pulled from the server is NOT marked dirty', () async {
      // Otherwise every pulled change is pushed straight back and the two
      // devices trade the same notebook forever.
      await db.applyRemoteNotebook(
        id: 'nb-remote',
        title: 'From the tablet',
        createdAt: 1,
        updatedAt: 2,
        docJson: '{}',
        inkJson: '{}',
        seq: 9,
      );

      expect(await db.notebooksNeedingPush(), isEmpty);
    });
  });

  group('tombstones', () {
    test('a deletion is remembered after the row is gone', () async {
      await insertNotebook('nb-1');
      await db.recordTombstone(entityType: 'notebook', entityId: 'nb-1');
      await (db.delete(db.notebooks)..where((t) => t.id.equals('nb-1'))).go();

      final List<SyncTombstoneRow> stones = await db.pendingTombstones();
      expect(stones.single.entityId, 'nb-1');
      expect(await db.getNotebookRow('nb-1'), isNull);
    });

    test('a confirmed deletion stops being resent', () async {
      await db.recordTombstone(entityType: 'notebook', entityId: 'nb-1');
      await db.clearTombstone(entityType: 'notebook', entityId: 'nb-1');

      expect(await db.pendingTombstones(), isEmpty);
    });

    test('recording the same deletion twice does not duplicate it', () async {
      await db.recordTombstone(entityType: 'notebook', entityId: 'nb-1');
      await db.recordTombstone(entityType: 'notebook', entityId: 'nb-1');

      expect(await db.pendingTombstones(), hasLength(1));
    });

    test('a remote deletion does not create a local tombstone', () async {
      // It is already in the server's log; recording it again would push it
      // back as though this device had originated it.
      await insertNotebook('nb-1');
      await db.applyRemoteNotebookDeletion('nb-1');

      expect(await db.pendingTombstones(), isEmpty);
      // Into the trash, not oblivion (user decision): the synced-in deletion
      // is recoverable for 7 days from Settings → Trash.
      final row = await db.getNotebookRow('nb-1');
      expect(row, isNotNull);
      expect(row!.deletedAt, isNotNull);
      expect(
        (await db.trashedNotebooks()).map((r) => r.id),
        contains('nb-1'),
      );
      // And a trashed row never pushes: its body on the peer is gone, and
      // pushing it would resurrect what the user just deleted.
      expect(
        (await db.notebooksNeedingPush()).map((r) => r.id),
        isNot(contains('nb-1')),
      );
    });
  });
}

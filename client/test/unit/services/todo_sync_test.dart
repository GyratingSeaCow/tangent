// SPDX-License-Identifier: AGPL-3.0-or-later
/// To Do arc Phase 1: todos through the document sync engine.
///
/// Todos follow the dump rules — flat data, never forks. Own-echo: a
/// local dirty row survives any incoming copy. Newer-wins: a stale peer
/// update cannot roll back a clean local row. Absent-key tolerance: an
/// older client's payload missing a key must not erase what this device
/// already holds, while a PRESENT null is authoritative.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/todo_repository.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _RecordingClient implements TranscriptionClient {
  List<Map<String, dynamic>>? pushedChanges;
  List<PushResult> pushResults = const <PushResult>[];
  List<SyncPullPage> pullPages = <SyncPullPage>[];

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {}

  @override
  Future<SyncPullPage> pullChanges({
    required String deviceId,
    required int sinceSeq,
  }) async {
    if (pullPages.isEmpty) {
      return SyncPullPage(changes: const [], headSeq: sinceSeq, hasMore: false);
    }
    return pullPages.removeAt(0);
  }

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async {
    pushedChanges = changes;
    return pushResults;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _OnlineConnectivity implements ConnectivityService {
  @override
  Future<ConnectivityStatus> currentStatus() async => ConnectivityStatus.wifi;

  @override
  Stream<ConnectivityStatus> get statusStream =>
      Stream<ConnectivityStatus>.value(ConnectivityStatus.wifi);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late LocalDb db;
  late _RecordingClient client;
  late TodoRepository repo;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    client = _RecordingClient();
    repo = TodoRepository(db: db, idFactory: () => 'todo-1');
  });

  tearDown(() async => db.close());

  DocumentSyncEngine build() => DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'test device',
        newDeviceId: 'device-under-test',
      );

  RemoteChange todoChange({
    int seq = 5,
    String id = 'remote-1',
    SyncOp op = SyncOp.upsert,
    Map<String, dynamic>? payload,
  }) =>
      RemoteChange(
        seq: seq,
        entityType: 'todo',
        entityId: id,
        op: op,
        payload: payload,
        deviceId: 'peer-device',
      );

  Map<String, dynamic> fullPayload({
    String text = 'from the peer',
    String updatedAt = '2026-09-27T10:00:00.000Z',
    Object? doneAt,
    Object? dueDate,
    Object? deletedAt,
  }) =>
      <String, dynamic>{
        'text': text,
        'done_at': doneAt,
        'due_date': dueDate,
        'source': 'manual',
        'source_ref': null,
        'created_at': '2026-09-27T09:00:00.000Z',
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
      };

  test('a dirty local todo pushes as entity_type todo with every field, '
      'and a confirmed push marks it clean', () async {
    final TodoRow added = await repo.add('pick up thermal paste');
    client.pushResults = <PushResult>[
      PushResult(
        entityId: added.id,
        entityType: 'todo',
        seq: 41,
        applied: true,
      ),
    ];

    await build().syncNow();

    final Map<String, dynamic> change = client.pushedChanges!
        .singleWhere((chg) => chg['entity_type'] == 'todo');
    expect(change['entity_id'], added.id);
    expect(change['op'], 'upsert');
    final Map<String, dynamic> payload =
        change['payload'] as Map<String, dynamic>;
    expect(payload['text'], 'pick up thermal paste');
    expect(payload.keys, contains('done_at'));
    expect(payload.keys, contains('due_date'));
    expect(payload.keys, contains('deleted_at'));
    expect(payload['updated_at'], added.updatedAt);

    final TodoRow after = (await db.getTodoRow(added.id))!;
    expect(after.syncDirty, isFalse);
    expect(after.syncedSeq, 41);
  });

  test('an incoming todo lands clean (no echo back on the next cycle)',
      () async {
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[todoChange(payload: fullPayload())],
        headSeq: 5,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    final TodoRow row = (await db.getTodoRow('remote-1'))!;
    expect(row.body, 'from the peer');
    expect(row.syncDirty, isFalse, reason: 'pulled content must not re-push');
    expect(client.pushedChanges, isNull, reason: 'nothing dirty to push');
  });

  test('a local dirty edit survives an incoming copy (own edit wins)',
      () async {
    await db.applyRemoteTodo(
      id: 'remote-1',
      text: 'original',
      createdAt: '2026-09-27T09:00:00.000Z',
      updatedAt: '2026-09-27T09:00:00.000Z',
      seq: 1,
    );
    await repo.editText('remote-1', 'my unpushed edit');
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          todoChange(
            payload: fullPayload(
              text: 'peer overwrite',
              updatedAt: '2126-01-01T00:00:00.000Z',
            ),
          ),
        ],
        headSeq: 5,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    final TodoRow row = (await db.getTodoRow('remote-1'))!;
    expect(row.body, 'my unpushed edit');
    expect(row.syncDirty, isTrue, reason: 'still owed to the server');
  });

  test('a stale incoming update is dropped (newer local wins)', () async {
    await db.applyRemoteTodo(
      id: 'remote-1',
      text: 'newer local copy',
      createdAt: '2026-09-27T09:00:00.000Z',
      updatedAt: '2026-09-27T12:00:00.000Z',
      seq: 3,
    );
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          todoChange(
            payload: fullPayload(
              text: 'stale peer copy',
              updatedAt: '2026-09-27T08:00:00.000Z',
            ),
          ),
        ],
        headSeq: 6,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    expect((await db.getTodoRow('remote-1'))!.body, 'newer local copy');
  });

  test('an absent key keeps the local value; a present null erases it',
      () async {
    await db.applyRemoteTodo(
      id: 'remote-1',
      text: 'dated and done',
      createdAt: '2026-09-27T09:00:00.000Z',
      updatedAt: '2026-09-27T09:00:00.000Z',
      dueDate: '2026-10-01',
      doneAt: '2026-09-27T09:30:00.000Z',
      seq: 1,
    );
    // An older client's payload without due_date/done_at keys at all.
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          todoChange(
            payload: <String, dynamic>{
              'text': 'renamed by an older client',
              'created_at': '2026-09-27T09:00:00.000Z',
              'updated_at': '2026-09-27T10:00:00.000Z',
            },
          ),
        ],
        headSeq: 7,
        hasMore: false,
      ),
    ];
    await build().syncNow();

    TodoRow row = (await db.getTodoRow('remote-1'))!;
    expect(row.body, 'renamed by an older client');
    expect(row.dueDate, '2026-10-01', reason: 'absence is not an eraser');
    expect(row.doneAt, '2026-09-27T09:30:00.000Z');

    // A present null IS the eraser: the peer unchecked and un-dated it.
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          todoChange(
            seq: 8,
            payload: fullPayload(
              text: 'renamed by an older client',
              updatedAt: '2026-09-27T11:00:00.000Z',
            ),
          ),
        ],
        headSeq: 8,
        hasMore: false,
      ),
    ];
    await build().syncNow();

    row = (await db.getTodoRow('remote-1'))!;
    expect(row.dueDate, isNull);
    expect(row.doneAt, isNull);
  });

  test('a peer soft delete arrives as a deleted_at upsert and hides the row',
      () async {
    await db.applyRemoteTodo(
      id: 'remote-1',
      text: 'doomed',
      createdAt: '2026-09-27T09:00:00.000Z',
      updatedAt: '2026-09-27T09:00:00.000Z',
      seq: 1,
    );
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          todoChange(
            seq: 9,
            payload: fullPayload(
              text: 'doomed',
              updatedAt: '2026-09-27T10:00:00.000Z',
              deletedAt: '2026-09-27T10:00:00.000Z',
            ),
          ),
        ],
        headSeq: 9,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    final TodoRow row = (await db.getTodoRow('remote-1'))!;
    expect(row.deletedAt, '2026-09-27T10:00:00.000Z');
    expect(
      await TodoRepository(db: db).watchTodos().first,
      isEmpty,
      reason: 'a synced-in delete leaves the list',
    );
  });

  test('a rejected todo stays dirty and retries next cycle', () async {
    final TodoRow added = await repo.add('rejected');
    client.pushResults = <PushResult>[
      PushResult(
        entityId: added.id,
        entityType: 'todo',
        seq: 0,
        applied: false,
        reason: 'malformed',
      ),
    ];

    await build().syncNow();

    expect((await db.getTodoRow(added.id))!.syncDirty, isTrue);
  });

  test('an edit made while the push was in flight stays dirty', () async {
    final TodoRow added = await repo.add('first text');
    client.pushResults = <PushResult>[
      PushResult(
        entityId: added.id,
        entityType: 'todo',
        seq: 50,
        applied: true,
      ),
    ];
    // The engine reads dirty rows, then the user edits before the ack
    // lands. Simulated by bumping updated_at after capture: markTodoSynced
    // is guarded on the PUSHED updated_at.
    await db.markTodoSynced(
      added.id,
      seq: 50,
      pushedUpdatedAt: 'some-older-stamp',
    );

    expect((await db.getTodoRow(added.id))!.syncDirty, isTrue);
  });

  test('sync leaves an untouched clean row alone', () async {
    await db.applyRemoteTodo(
      id: 'remote-1',
      text: 'clean',
      createdAt: '2026-09-27T09:00:00.000Z',
      updatedAt: '2026-09-27T09:00:00.000Z',
      seq: 1,
    );
    await (db.update(db.todos)
          ..where((t) => t.id.equals('remote-1')))
        .write(const TodosCompanion(syncDirty: Value(false)));

    await build().syncNow();

    expect(client.pushedChanges, isNull);
  });
}

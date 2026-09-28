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
import 'package:tangent/services/todo_voice_capture.dart';
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
    expect(payload.keys, contains('folder_id'));
    expect(payload['updated_at'], added.updatedAt);

    final TodoRow after = (await db.getTodoRow(added.id))!;
    expect(after.syncDirty, isFalse);
    expect(after.syncedSeq, 41);
  });

  group('folders (v1.24.0)', () {
    test('folder_id round-trips: a moved todo pushes its folder with a '
        'FRESH updated_at, and a pulled folder_id lands on the row', () async {
      // The row arrived from a peer at T0; the local move must stamp later
      // than T0 or the server's newer-wins rule drops the move as stale.
      const String t0 = '2026-09-27T09:00:00.000Z';
      await db.applyRemoteTodo(
        id: 'remote-1',
        text: 'buy filament',
        createdAt: t0,
        updatedAt: t0,
        seq: 1,
      );
      final DateTime moveClock = DateTime.utc(2026, 9, 27, 11);
      final TodoRepository movingRepo =
          TodoRepository(db: db, now: () => moveClock);
      await movingRepo.moveToFolder('remote-1', 'folder-shop');

      client.pushResults = <PushResult>[
        PushResult(
          entityId: 'remote-1',
          entityType: 'todo',
          seq: 42,
          applied: true,
        ),
      ];
      await build().syncNow();

      final Map<String, dynamic> payload = client.pushedChanges!
          .singleWhere((chg) => chg['entity_type'] == 'todo')['payload']
          as Map<String, dynamic>;
      expect(payload['folder_id'], 'folder-shop', reason: 'push carries it');
      expect(
        payload['updated_at'],
        moveClock.toIso8601String(),
        reason: 'moveToFolder must bump updated_at past the peer stamp',
      );
      expect(
        (payload['updated_at'] as String).compareTo(t0) > 0,
        isTrue,
        reason: 'stale stamp would lose to newer-wins on the server',
      );

      // The other direction: a peer files it elsewhere.
      client.pullPages = <SyncPullPage>[
        SyncPullPage(
          changes: <RemoteChange>[
            todoChange(
              seq: 50,
              payload: fullPayload(
                text: 'buy filament',
                updatedAt: '2026-09-27T12:00:00.000Z',
              )..['folder_id'] = 'folder-workshop',
            ),
          ],
          headSeq: 50,
          hasMore: false,
        ),
      ];
      await build().syncNow();
      expect((await db.getTodoRow('remote-1'))!.folderId, 'folder-workshop');
    });

    test('a payload WITHOUT folder_id keeps the local filing; a present '
        'null unfiles', () async {
      await db.applyRemoteTodo(
        id: 'remote-1',
        text: 'filed',
        createdAt: '2026-09-27T09:00:00.000Z',
        updatedAt: '2026-09-27T09:00:00.000Z',
        folderId: 'folder-shop',
        seq: 1,
      );
      client.pullPages = <SyncPullPage>[
        SyncPullPage(
          changes: <RemoteChange>[
            todoChange(
              seq: 6,
              payload: <String, dynamic>{
                'text': 'renamed by a pre-1.24 client',
                'created_at': '2026-09-27T09:00:00.000Z',
                'updated_at': '2026-09-27T10:00:00.000Z',
              },
            ),
          ],
          headSeq: 6,
          hasMore: false,
        ),
      ];
      await build().syncNow();
      TodoRow row = (await db.getTodoRow('remote-1'))!;
      expect(row.body, 'renamed by a pre-1.24 client');
      expect(row.folderId, 'folder-shop', reason: 'absent key preserves');

      client.pullPages = <SyncPullPage>[
        SyncPullPage(
          changes: <RemoteChange>[
            todoChange(
              seq: 7,
              payload: fullPayload(updatedAt: '2026-09-27T11:00:00.000Z')
                ..['folder_id'] = null,
            ),
          ],
          headSeq: 7,
          hasMore: false,
        ),
      ];
      await build().syncNow();
      row = (await db.getTodoRow('remote-1'))!;
      expect(row.folderId, isNull, reason: 'explicit null unfiles');
    });

    test('moveManyToFolder files the whole set, dirty with fresh stamps',
        () async {
      final DateTime t0 = DateTime.utc(2026, 9, 27, 9);
      final DateTime t1 = DateTime.utc(2026, 9, 27, 10);
      DateTime clock = t0;
      int n = 0;
      final TodoRepository r = TodoRepository(
        db: db,
        idFactory: () => 'id-${n++}',
        now: () => clock,
      );
      await r.add('one');
      await r.add('two');
      await r.add('three');
      await db.markTodoSynced('id-0', seq: 1, pushedUpdatedAt: t0.toIso8601String());
      await db.markTodoSynced('id-1', seq: 1, pushedUpdatedAt: t0.toIso8601String());

      clock = t1;
      await r.moveManyToFolder(<String>['id-0', 'id-1'], 'folder-shop');

      for (final String id in <String>['id-0', 'id-1']) {
        final TodoRow row = (await db.getTodoRow(id))!;
        expect(row.folderId, 'folder-shop');
        expect(row.syncDirty, isTrue);
        expect(row.updatedAt, t1.toIso8601String());
      }
      expect((await db.getTodoRow('id-2'))!.folderId, isNull);
    });

    test('deleting a folder unfiles its todos in the same transaction',
        () async {
      final String shop = await db.createFolder(name: 'Shop');
      final TodoRow a = await repo.add('in shop');
      await repo.moveToFolder(a.id, shop);
      await db.markTodoSynced(a.id, seq: 3, pushedUpdatedAt: (await db.getTodoRow(a.id))!.updatedAt);

      await db.deleteFolder(shop);

      final TodoRow after = (await db.getTodoRow(a.id))!;
      expect(after.folderId, isNull);
      expect(after.deletedAt, isNull, reason: 'contents are kept');
      expect(after.syncDirty, isTrue, reason: 'unfiled state must push');
    });
  });

  test(
      'capture_fingerprint is local-only: never pushed, never read from a '
      'pull', () async {
    await captureVoiceTodos(
      db: db,
      dumpId: 'dump-1',
      transcript: 'add to my to do list pick up thermal paste',
      recordedOn: DateTime(2026, 9, 27),
      repository: repo,
    );
    final TodoRow captured = (await repo.todosFromSource('dump-1')).single;
    expect(captured.captureFingerprint, isNotNull);
    client.pushResults = <PushResult>[
      PushResult(
        entityId: captured.id,
        entityType: 'todo',
        seq: 41,
        applied: true,
      ),
    ];
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          todoChange(
            id: 'remote-1',
            payload: <String, dynamic>{
              ...fullPayload(),
              'capture_fingerprint': 'peer-fingerprint',
            },
          ),
        ],
        headSeq: 5,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    final Map<String, dynamic> pushed = client.pushedChanges!
        .singleWhere((chg) => chg['entity_type'] == 'todo');
    expect(
      (pushed['payload'] as Map<String, dynamic>).keys,
      isNot(contains('capture_fingerprint')),
    );
    expect((await db.getTodoRow('remote-1'))!.captureFingerprint, isNull);
    expect(
      (await db.getTodoRow(captured.id))!.captureFingerprint,
      captured.captureFingerprint,
      reason: 'a confirmed push does not clear the local value',
    );
  });

  group('cross-device dedupe on pull (v1.28.0)', () {
    Map<String, dynamic> voicePayload({
      required String text,
      String? sourceRef = 'dump-1',
      required String createdAt,
    }) =>
        <String, dynamic>{
          'text': text,
          'done_at': null,
          'due_date': null,
          'source': 'voice',
          'source_ref': sourceRef,
          'created_at': createdAt,
          'updated_at': createdAt,
          'deleted_at': null,
          'folder_id': null,
        };

    Future<TodoRow> localVoiceRow({
      String id = 'local-1',
      String text = 'pick up thermal paste',
      String sourceRef = 'dump-1',
      required String createdAt,
      String? deletedAt,
    }) async {
      await db.applyRemoteTodo(
        id: id,
        text: text,
        source: 'voice',
        sourceRef: sourceRef,
        createdAt: createdAt,
        updatedAt: createdAt,
        deletedAt: deletedAt,
        seq: 1,
      );
      return (await db.getTodoRow(id))!;
    }

    Future<void> pull(Map<String, dynamic> payload, {String id = 'remote-1'}) {
      client.pullPages = <SyncPullPage>[
        SyncPullPage(
          changes: <RemoteChange>[todoChange(id: id, payload: payload)],
          headSeq: 5,
          hasMore: false,
        ),
      ];
      return build().syncNow();
    }

    test(
        'a NEWER remote duplicate is applied then soft-deleted; the local '
        'row is kept', () async {
      await localVoiceRow(createdAt: '2026-09-27T09:00:00.000Z');

      await pull(
        voicePayload(
          text: 'pick up thermal paste',
          createdAt: '2026-09-27T09:05:00.000Z',
        ),
      );

      final TodoRow local = (await db.getTodoRow('local-1'))!;
      final TodoRow remote = (await db.getTodoRow('remote-1'))!;
      expect(local.deletedAt, isNull);
      expect(remote.body, 'pick up thermal paste', reason: 'applied first');
      expect(remote.deletedAt, isNotNull);
      expect(
        remote.syncDirty,
        isTrue,
        reason: 'the soft delete travels back as a normal delete',
      );
      expect(
        (await repo.listTodos()).map((r) => r.id),
        ['local-1'],
      );
    });

    test(
        'the reverse ordering (OLDER remote) keeps the remote and '
        'soft-deletes the local', () async {
      await localVoiceRow(createdAt: '2026-09-27T09:05:00.000Z');

      await pull(
        voicePayload(
          text: 'pick up thermal paste',
          createdAt: '2026-09-27T09:00:00.000Z',
        ),
      );

      expect((await db.getTodoRow('remote-1'))!.deletedAt, isNull);
      final TodoRow local = (await db.getTodoRow('local-1'))!;
      expect(local.deletedAt, isNotNull);
      expect(local.syncDirty, isTrue);
    });

    test(
        'a soft-deleted local twin is not a dedupe candidate (Undo is not '
        'reversed, and the remote stays live)', () async {
      await localVoiceRow(
        createdAt: '2026-09-27T09:00:00.000Z',
        deletedAt: '2026-09-27T09:30:00.000Z',
      );

      await pull(
        voicePayload(
          text: 'pick up thermal paste',
          createdAt: '2026-09-27T09:05:00.000Z',
        ),
      );

      expect((await db.getTodoRow('remote-1'))!.deletedAt, isNull);
      expect(
        (await db.getTodoRow('local-1'))!.deletedAt,
        '2026-09-27T09:30:00.000Z',
      );
    });

    test('two different recordings with the same item text do NOT collapse',
        () async {
      await localVoiceRow(
        sourceRef: 'dump-1',
        createdAt: '2026-09-27T09:00:00.000Z',
      );

      await pull(
        voicePayload(
          text: 'pick up thermal paste',
          sourceRef: 'dump-2',
          createdAt: '2026-09-27T09:05:00.000Z',
        ),
      );

      expect((await db.getTodoRow('local-1'))!.deletedAt, isNull);
      expect((await db.getTodoRow('remote-1'))!.deletedAt, isNull);
      expect((await repo.listTodos()).length, 2);
    });

    test('different text under the same recording is two items', () async {
      await localVoiceRow(createdAt: '2026-09-27T09:00:00.000Z');

      await pull(
        voicePayload(
          text: 'email the Zionsville customer back',
          createdAt: '2026-09-27T09:05:00.000Z',
        ),
      );

      expect((await repo.listTodos()).length, 2);
    });

    test('a manual item is never deduped against a voice twin', () async {
      await db.applyRemoteTodo(
        id: 'local-1',
        text: 'pick up thermal paste',
        source: 'manual',
        sourceRef: 'dump-1',
        createdAt: '2026-09-27T09:00:00.000Z',
        updatedAt: '2026-09-27T09:00:00.000Z',
        seq: 1,
      );

      await pull(
        voicePayload(
          text: 'pick up thermal paste',
          createdAt: '2026-09-27T09:05:00.000Z',
        ),
      );

      expect((await repo.listTodos()).length, 2);
    });
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

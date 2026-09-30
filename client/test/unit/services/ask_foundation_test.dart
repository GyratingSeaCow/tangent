// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/ask_history_repository.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/ask_client.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _Dio extends Mock implements Dio {}

class _Client implements TranscriptionClient {
  List<SyncPullPage> pages = <SyncPullPage>[];
  List<Map<String, dynamic>>? pushed;
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
  }) async =>
      pages.isEmpty
          ? SyncPullPage(changes: const [], headSeq: sinceSeq, hasMore: false)
          : pages.removeAt(0);
  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async {
    pushed = changes;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Online implements ConnectivityService {
  @override
  Future<ConnectivityStatus> currentStatus() async => ConnectivityStatus.wifi;
  @override
  Stream<ConnectivityStatus> get statusStream =>
      Stream.value(ConnectivityStatus.wifi);
}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
  });

  test('POST /v1/ask sends literal wire shape and parses 42.5 second source',
      () async {
    final _Dio dio = _Dio();
    when(() => dio.post<dynamic>('/v1/ask', data: any(named: 'data')))
        .thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/v1/ask'),
        statusCode: 200,
        data: <String, dynamic>{
          'answer': 'At lunch',
          'sources': <dynamic>[
            <String, dynamic>{
              'entity_type': 'dump',
              'entity_id': 'dump-9',
              'snippet': 'meet at lunch',
              'seek_seconds': 42.5,
            }
          ],
        },
      ),
    );
    final AskResponse result =
        await AskClient.forTesting(dio: dio).ask('When?');
    verify(
      () => dio.post<dynamic>(
        '/v1/ask',
        data: <String, dynamic>{'question': 'When?'},
      ),
    ).called(1);
    expect(result.answer, 'At lunch');
    expect(result.sources.single.seekSeconds, 42.5);
    expect(result.sources.single.entityType, 'dump');
  });

  test(
      'remote ask rows are idempotent, source-complete, and stable at equal timestamps',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _Client client = _Client();
    final List<RemoteChange> changes = <RemoteChange>[
      RemoteChange(
        seq: 101,
        entityType: 'ask_message',
        entityId: 'u-server',
        op: SyncOp.upsert,
        deviceId: 'server',
        payload: <String, dynamic>{
          'role': 'user',
          'text': 'When?',
          'sources': <dynamic>[],
          'created_at': 200,
        },
      ),
      RemoteChange(
        seq: 102,
        entityType: 'ask_message',
        entityId: 'a-server',
        op: SyncOp.upsert,
        deviceId: 'server',
        payload: <String, dynamic>{
          'role': 'assistant',
          'text': 'At lunch',
          'sources': <dynamic>[
            <String, dynamic>{
              'entity_type': 'dump',
              'entity_id': 'd9',
              'snippet': 'lunch',
              'seek_seconds': 42.5,
            }
          ],
          'created_at': 200,
        },
      ),
    ];
    client.pages = <SyncPullPage>[
      SyncPullPage(changes: changes, headSeq: 102, hasMore: false),
    ];
    final DocumentSyncEngine engine = DocumentSyncEngine(
      db: () => db,
      client: () => client,
      connectivity: _Online(),
      deviceLabel: () async => 'test',
      newDeviceId: 'device-ask-1',
    );
    await engine.syncNow();
    client.pages = <SyncPullPage>[
      SyncPullPage(changes: changes, headSeq: 102, hasMore: false),
    ];
    await engine.syncNow();
    final List<AskHistoryMessage> rows = await AskHistoryRepository(db).list();
    expect(rows.map((r) => r.id), <String>['u-server', 'a-server']);
    expect(rows.last.sources.single.toJson(), <String, dynamic>{
      'entity_type': 'dump',
      'entity_id': 'd9',
      'snippet': 'lunch',
      'seek_seconds': 42.5,
    });
  });

  test('remote ask delete ops are ignored: no fabricated row, history intact',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _Client client = _Client();
    client.pages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          RemoteChange(
            seq: 201,
            entityType: 'ask_message',
            entityId: 'keep-me',
            op: SyncOp.upsert,
            deviceId: 'server',
            payload: <String, dynamic>{
              'role': 'assistant',
              'text': 'kept answer',
              'sources': <dynamic>[],
              'created_at': 300,
            },
          ),
          RemoteChange(
            seq: 202,
            entityType: 'ask_message',
            entityId: 'keep-me',
            op: SyncOp.delete,
            deviceId: 'server',
            payload: null,
          ),
        ],
        headSeq: 202,
        hasMore: false,
      ),
    ];
    final DocumentSyncEngine engine = DocumentSyncEngine(
      db: () => db,
      client: () => client,
      connectivity: _Online(),
      deviceLabel: () async => 'test',
      newDeviceId: 'device-ask-3',
    );
    await engine.syncNow();
    final List<AskHistoryMessage> rows = await AskHistoryRepository(db).list();
    // The delete op must not remove the already-materialized server row.
    expect(rows.map((r) => r.id), <String>['keep-me']);
    expect(rows.single.text, 'kept answer');
  });

  test('engine never pushes ask messages or ask tombstones', () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.applyRemoteAskMessage(
      id: 'server-id',
      role: 'assistant',
      text: 'answer',
      sourcesJson: '[]',
      createdAt: 1,
      seq: 4,
    );
    await db.customStatement(
      "INSERT INTO sync_tombstones(entity_type,entity_id,deleted_at) VALUES('ask_message','server-id',1)",
    );
    final _Client client = _Client();
    final DocumentSyncEngine engine = DocumentSyncEngine(
      db: () => db,
      client: () => client,
      connectivity: _Online(),
      deviceLabel: () async => 'test',
      newDeviceId: 'device-ask-2',
    );
    await engine.syncNow();
    expect(
      client.pushed ?? const <Map<String, dynamic>>[],
      isNot(
        contains(
          predicate((dynamic c) => c['entity_type'] == 'ask_message'),
        ),
      ),
    );
  });

  test('server tombstone prevents discarded Ask recording resurrection',
      () async {
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const id = 'ask-voice-short';
    await db.applyRemoteDumpDeletion(id);
    final _Client client = _Client();
    client.pages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          RemoteChange(
            seq: 301,
            entityType: 'dump',
            entityId: id,
            op: SyncOp.upsert,
            deviceId: 'server',
            payload: <String, dynamic>{
              'mode': 'brain_dump',
              'title': 'Temporary Ask voice',
              'transcript': 'Where is Zephyr?',
              'duration_seconds': 24,
              'audio_kept': true,
              'created_at': 1700000000,
              'updated_at': 1700000024,
            },
          ),
          const RemoteChange(
            seq: 302,
            entityType: 'dump',
            entityId: id,
            op: SyncOp.delete,
            deviceId: 'server',
            payload: null,
          ),
        ],
        headSeq: 302,
        hasMore: false,
      ),
    ];
    final engine = DocumentSyncEngine(
      db: () => db,
      client: () => client,
      connectivity: _Online(),
      deviceLabel: () async => 'test',
      newDeviceId: 'device-ask-discard',
    );
    await engine.syncNow();
    expect(await db.getDumpRow(id), isNull);
    expect(
      await db.listDumps(),
      isNot(contains(predicate((DumpRow row) => row.id == id))),
    );
  });
}

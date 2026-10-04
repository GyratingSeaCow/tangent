// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared tags through the REAL DocumentSyncEngine: what it pushes (and in
// what order), how acknowledgements clean rows, and how pulled tag and
// assignment changes land. The seam under test is engine ↔ LocalDb ↔ wire;
// LocalDb's own rules are covered in tag_store_test.dart.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _RecordingClient implements TranscriptionClient {
  List<Map<String, dynamic>>? pushedChanges;

  /// Acknowledge every pushed change as applied, seq numbered from 100.
  bool acceptAll = true;

  /// Runs while the push is "in flight", before results come back.
  Future<void> Function()? duringPush;
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
    await duringPush?.call();
    if (!acceptAll) return const <PushResult>[];
    int seq = 100;
    return <PushResult>[
      for (final Map<String, dynamic> c in changes)
        PushResult(
          entityId: c['entity_id'] as String,
          entityType: c['entity_type'] as String,
          seq: seq++,
          applied: true,
        ),
    ];
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

RemoteChange _change(
  String type,
  String id,
  SyncOp op,
  int seq, [
  Map<String, dynamic>? payload,
]) => RemoteChange(
  entityType: type,
  entityId: id,
  op: op,
  payload: payload,
  seq: seq,
  deviceId: 'peer-device',
);

void main() {
  late LocalDb db;
  late _RecordingClient client;
  late DocumentSyncEngine engine;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    client = _RecordingClient();
    engine = DocumentSyncEngine(
      db: () => db,
      client: () => client,
      connectivity: _OnlineConnectivity(),
      deviceLabel: () async => 'test',
      newDeviceId: 'device-under-test',
    );
  });

  tearDown(() async => db.close());

  Future<void> insertNotebook(String id) => db
      .into(db.notebooks)
      .insert(
        NotebooksCompanion.insert(
          id: id,
          title: 'Notebook',
          createdAt: 1,
          updatedAt: 2,
          docJson: '{}',
          inkJson: '{}',
        ),
      );

  test(
    'tags push before targets and assignments after; acks clean them',
    () async {
      await insertNotebook('nb-1');
      final String tag = await db.createTag('Work');
      await db.assignTag(tagId: tag, targetType: 'notebook', targetId: 'nb-1');
      await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'dump-1');

      final SyncReport report = await engine.syncNow();
      expect(report.outcome, SyncOutcome.success, reason: report.error);

      final List<Map<String, dynamic>> pushed = client.pushedChanges!;
      final List<String> types = pushed
          .map((c) => c['entity_type'] as String)
          .toList();
      final int tagAt = types.indexOf('tag');
      final int notebookAt = types.indexOf('notebook');
      final int firstAssignment = types.indexOf('tag_assignment');
      expect(tagAt, isNot(-1));
      expect(tagAt < notebookAt, isTrue, reason: 'tag precedes its targets');
      expect(firstAssignment > notebookAt, isTrue);
      expect(types.where((t) => t == 'tag_assignment'), hasLength(2));

      expect(pushed[tagAt]['payload'], containsPair('name', 'Work'));
      final Map<String, dynamic> nbAssign = pushed.firstWhere(
        (c) =>
            c['entity_type'] == 'tag_assignment' &&
            c['payload']['target_type'] == 'notebook',
      );
      expect(
        nbAssign['entity_id'],
        LocalDb.tagAssignmentId(tag, 'notebook', 'nb-1'),
      );
      expect(nbAssign['payload'], <String, dynamic>{
        'tag_id': tag,
        'target_type': 'notebook',
        'target_id': 'nb-1',
        'created_at': isA<int>(),
      });

      expect(await db.tagsNeedingPush(), isEmpty);
      expect(await db.tagAssignmentsNeedingPush(), isEmpty);
    },
  );

  test('a rename landing while the push is in flight stays dirty', () async {
    final String tag = await db.createTag('Work');
    client.duringPush = () => db.renameTag(
      tag,
      'Job',
      now: DateTime.now().add(const Duration(seconds: 5)),
    );

    await engine.syncNow();

    expect((await db.tagsNeedingPush()).map((TagRow t) => t.name), <String>[
      'Job',
    ], reason: 'clearing it would strand the rename forever');
  });

  test(
    'deleting a tag pushes ONE tag tombstone and the ack clears it',
    () async {
      final String tag = await db.createTag('Work');
      await db.assignTag(tagId: tag, targetType: 'notebook', targetId: 'n1');
      await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
      await engine.syncNow();

      await db.deleteTag(tag);
      await engine.syncNow();

      expect(client.pushedChanges, <Map<String, dynamic>>[
        <String, dynamic>{
          'entity_type': 'tag',
          'entity_id': tag,
          'op': 'delete',
        },
      ]);
      expect(await db.pendingTombstones(), isEmpty);
    },
  );

  test('removing a tag from one item pushes that assignment delete', () async {
    final String tag = await db.createTag('Work');
    await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
    await engine.syncNow();

    await db.unassignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
    await engine.syncNow();

    expect(client.pushedChanges, <Map<String, dynamic>>[
      <String, dynamic>{
        'entity_type': 'tag_assignment',
        'entity_id': LocalDb.tagAssignmentId(tag, 'dump', 'd1'),
        'op': 'delete',
      },
    ]);
    expect(await db.pendingTombstones(), isEmpty);
  });

  test('an unacknowledged push leaves tags and assignments dirty', () async {
    final String tag = await db.createTag('Work');
    await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
    client.acceptAll = false;

    await engine.syncNow();

    expect(await db.tagsNeedingPush(), hasLength(1));
    expect(await db.tagAssignmentsNeedingPush(), hasLength(1));
  });

  test('pulled tags and assignments land clean and are not echoed', () async {
    final String nbAssign = LocalDb.tagAssignmentId('t1', 'notebook', 'nb-1');
    final String dumpAssign = LocalDb.tagAssignmentId('t1', 'dump', 'd-1');
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          _change('tag', 't1', SyncOp.upsert, 1, <String, dynamic>{
            'name': 'From the tablet',
            'created_at': 5,
            'updated_at': 6,
          }),
          _change(
            'tag_assignment',
            nbAssign,
            SyncOp.upsert,
            2,
            <String, dynamic>{
              'tag_id': 't1',
              'target_type': 'notebook',
              'target_id': 'nb-1',
              'created_at': 7,
            },
          ),
          _change(
            'tag_assignment',
            dumpAssign,
            SyncOp.upsert,
            3,
            <String, dynamic>{
              'tag_id': 't1',
              'target_type': 'dump',
              'target_id': 'd-1',
              'created_at': 7,
            },
          ),
        ],
        headSeq: 3,
        hasMore: false,
      ),
    ];

    await engine.syncNow();

    expect((await db.allTags()).single.name, 'From the tablet');
    expect(await db.watchTagLinks('notebook').first, hasLength(1));
    expect(await db.watchTagLinks('dump').first, hasLength(1));
    expect(client.pushedChanges, isNull, reason: 'nothing dirty to echo');

    // The tag's deletion arrives: every notebook AND dump loses it.
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[_change('tag', 't1', SyncOp.delete, 4)],
        headSeq: 4,
        hasMore: false,
      ),
    ];
    await engine.syncNow();

    expect(await db.allTags(), isEmpty);
    expect(await db.select(db.tagAssignments).get(), isEmpty);
    expect(await db.pendingTombstones(), isEmpty);
  });

  test(
    'a peer assignment pulled after this device deleted (and pushed the '
    'deletion of) its tag never lands',
    () async {
      final String tag = await db.createTag('Work');
      await engine.syncNow(); // tag pushed and acknowledged
      await db.deleteTag(tag);
      await engine.syncNow(); // tag delete pushed; tombstone cleared
      expect(await db.pendingTombstones(), isEmpty);

      // The peer tagged a dump before it saw the deletion. Its upsert sits
      // EARLIER in the feed than the delete, and the delete is this
      // device's own push, so it is never echoed back to clean up after.
      final String assign = LocalDb.tagAssignmentId(tag, 'dump', 'd-1');
      client.pushedChanges = null;
      client.pullPages = <SyncPullPage>[
        SyncPullPage(
          changes: <RemoteChange>[
            _change(
              'tag_assignment',
              assign,
              SyncOp.upsert,
              101,
              <String, dynamic>{
                'tag_id': tag,
                'target_type': 'dump',
                'target_id': 'd-1',
                'created_at': 7,
              },
            ),
          ],
          headSeq: 101,
          hasMore: false,
        ),
      ];
      await engine.syncNow();

      expect(await db.select(db.tagAssignments).get(), isEmpty);
      expect(await db.tagAssignmentCount(tag), 0);
      expect(client.pushedChanges, isNull);
    },
  );

  test('an assignment whose tag is gone locally is never pushed', () async {
    await db
        .into(db.tagAssignments)
        .insert(
          TagAssignmentsCompanion.insert(
            id: LocalDb.tagAssignmentId('ghost', 'dump', 'd1'),
            tagId: 'ghost',
            targetType: 'dump',
            targetId: 'd1',
            createdAt: 1,
            syncDirty: const Value<bool?>(true),
          ),
        );

    await engine.syncNow();

    expect(client.pushedChanges, isNull);
  });
}

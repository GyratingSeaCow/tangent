// SPDX-License-Identifier: AGPL-3.0-or-later
/// Spec 2026-09-28 N4, the sync-engine hook: a pull carrying `summary`
/// for a row THIS device asked about (summaryRequestedAt set) calls the
/// notifier exactly once — not again on the next pull of the same row —
/// and a summary another device asked for is never reported.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _ScriptedClient implements TranscriptionClient {
  _ScriptedClient(this.pages);

  /// One page per syncNow(); the same change can be served twice to model
  /// a peer echo / re-pull.
  final List<List<RemoteChange>> pages;
  int _cursor = 0;

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
    if (_cursor >= pages.length) {
      return const SyncPullPage(changes: [], headSeq: 0, hasMore: false);
    }
    final List<RemoteChange> page = pages[_cursor++];
    return SyncPullPage(
      changes: page,
      headSeq: page.isEmpty ? 0 : page.last.seq,
      hasMore: false,
    );
  }

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async =>
      <PushResult>[
        for (final Map<String, dynamic> c in changes)
          PushResult(
            entityId: c['entity_id'] as String,
            entityType: c['entity_type'] as String,
            seq: 99,
            applied: true,
          ),
      ];

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

RemoteChange summaryChange({
  required String id,
  required int seq,
  required int summarizedAt,
  String summary = 'Decisions: ship it.',
  String template = 'meeting',
}) {
  return RemoteChange(
    seq: seq,
    entityType: 'dump',
    entityId: id,
    op: SyncOp.upsert,
    deviceId: serverDeviceId,
    payload: <String, dynamic>{
      'mode': 'meeting',
      'title': 'Planning',
      'transcript': 'we talked',
      'meeting_notes': null,
      'duration_seconds': 30,
      'audio_kept': true,
      'created_at': 1790000000,
      'updated_at': summarizedAt,
      'summary': summary,
      'summary_model': 'llama',
      'summarized_at': summarizedAt,
      'summary_template': template,
      'summary_status': null,
    },
  );
}

void main() {
  late LocalDb db;
  late List<({String dumpId, String title, String? template, int requestedAt})>
      landed;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    landed = [];
  });
  tearDown(() async => db.close());

  DocumentSyncEngine build(_ScriptedClient client) => DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'SM-X520',
        newDeviceId: 'device-under-test',
        onSummaryLanded: ({
          required dumpId,
          required title,
          required template,
          required requestedAt,
        }) =>
            landed.add((
          dumpId: dumpId,
          title: title,
          template: template,
          requestedAt: requestedAt,
        ),),
      );

  Future<void> seed(String id) async {
    await db.into(db.dumps).insert(
          DumpsCompanion.insert(
            id: id,
            createdAt: DateTime.utc(2026, 9, 28, 12),
            updatedAt: DateTime.utc(2026, 9, 28, 12),
            mode: 'meeting',
            durationSeconds: 30,
            title: 'Planning',
            audioPath: '/storage/emulated/0/Tangent/$id.opus',
            audioSizeBytes: 4096,
            syncStatus: 'synced',
          ),
        );
  }

  test('a pull landing the summary THIS device asked for reports exactly once',
      () async {
    await seed('d1');
    // The summarize 202 stamps summaryRequestedAt (the summaryPending
    // contract): this device asked.
    final DateTime asked = DateTime.utc(2026, 9, 28, 12, 0, 0);
    await db.recordRequestedSummaryTemplate('d1', 'meeting', now: asked);
    final int answeredAt = asked.millisecondsSinceEpoch ~/ 1000 + 60;

    final RemoteChange change =
        summaryChange(id: 'd1', seq: 10, summarizedAt: answeredAt);
    // Served on two consecutive syncs: a re-pull / peer echo of the same
    // row must not announce twice.
    final DocumentSyncEngine engine = build(
      _ScriptedClient(<List<RemoteChange>>[
        <RemoteChange>[change],
        <RemoteChange>[change],
      ]),
    );

    await engine.syncNow();
    expect(landed, hasLength(1), reason: 'the answer landed: tell the user');
    expect(landed.single.dumpId, 'd1');
    expect(landed.single.title, 'Planning');
    expect(landed.single.template, 'meeting');
    expect(
      landed.single.requestedAt,
      asked.millisecondsSinceEpoch ~/ 1000,
    );

    await engine.syncNow();
    expect(
      landed,
      hasLength(1),
      reason: 'the next pull of the same row must not fire again',
    );
    expect((await db.getDumpRow('d1'))!.summaryRequestedAt, isNull);
  });

  test('a summary another device asked for lands silently', () async {
    await seed('d2');
    // No recordRequestedSummaryTemplate: summaryRequestedAt is null.
    final DocumentSyncEngine engine = build(
      _ScriptedClient(<List<RemoteChange>>[
        <RemoteChange>[summaryChange(id: 'd2', seq: 11, summarizedAt: 1790000060)],
      ]),
    );
    await engine.syncNow();
    expect((await db.getDumpRow('d2'))!.summary, 'Decisions: ship it.');
    expect(landed, isEmpty, reason: "not this device's request");
  });

  test('a stale echo older than the request is not the answer', () async {
    await seed('d3');
    final DateTime asked = DateTime.utc(2026, 9, 28, 12);
    await db.recordRequestedSummaryTemplate('d3', 'meeting', now: asked);
    final int older = asked.millisecondsSinceEpoch ~/ 1000 - 3600;
    // A peer echoing the PREVIOUS summary, which this row already holds.
    await (db.update(db.dumps)..where((d) => d.id.equals('d3'))).write(
      const DumpsCompanion(summary: Value<String?>('old notes')),
    );
    final DocumentSyncEngine engine = build(
      _ScriptedClient(<List<RemoteChange>>[
        <RemoteChange>[
          summaryChange(id: 'd3', seq: 12, summarizedAt: older, summary: 'old notes'),
        ],
      ]),
    );
    await engine.syncNow();
    expect(landed, isEmpty, reason: 'nothing new to announce');
    expect(
      (await db.getDumpRow('d3'))!.summaryRequestedAt,
      isNotNull,
      reason: 'the request is still open',
    );
  });
}

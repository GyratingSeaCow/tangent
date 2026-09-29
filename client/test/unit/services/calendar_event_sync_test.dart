// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.35.0: calendar events through the document sync engine.
///
/// Same rules as todos (own-echo, newer-wins, absent-key tolerance) plus the
/// projection that matters for this entity: the three `google_*` columns are
/// server-authored and `capture_fingerprint` is local-only — NONE of the four
/// rides a device push, and a pull is the only way the Google fields land.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/calendar_event_repository.dart';
import 'package:tangent/data/local_db.dart';
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
  late CalendarEventRepository repo;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    client = _RecordingClient();
    // Pinned BEFORE every remote stamp in this file so newer-wins is
    // exercised deliberately, not by the wall clock.
    repo = CalendarEventRepository(
      db: db,
      idFactory: () => 'ev-1',
      now: () => DateTime.utc(2026, 9, 28, 20),
    );
  });

  tearDown(() async => db.close());

  DocumentSyncEngine build() => DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'test device',
        newDeviceId: 'device-under-test',
      );

  Future<CalendarEventRow> addDentist() => repo.add(
        title: 'Dentist',
        start: '2026-10-01T14:00:00',
        end: '2026-10-01T15:00:00',
        allDay: false,
        timeZone: 'America/New_York',
        needsDate: false,
        sourceRef: 'dump-1',
        captureFingerprint: 'fp-1',
      );

  Map<String, dynamic> remotePayload({
    String title = 'Dentist',
    String start = '2026-10-01T14:00:00',
    String updatedAt = '2026-09-28T21:00:00.000Z',
    Object? googleEventId = 'g1',
    Object? googleHtmlLink = 'https://calendar.google.com/event?eid=g1',
    int needsDate = 0,
    Object? deletedAt,
  }) =>
      <String, dynamic>{
        'title': title,
        'start': start,
        'end': '2026-10-01T15:00:00',
        'all_day': 0,
        'time_zone': 'America/New_York',
        'needs_date': needsDate,
        'source': 'voice',
        'source_ref': 'dump-1',
        'created_at': '2026-09-28T20:00:00.000Z',
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
        'google_event_id': googleEventId,
        'google_html_link': googleHtmlLink,
        'google_updated': '2026-09-28T21:00:00.000Z',
      };

  RemoteChange change({
    int seq = 5,
    SyncOp op = SyncOp.upsert,
    Map<String, dynamic>? payload,
  }) =>
      RemoteChange(
        seq: seq,
        entityType: 'calendar_event',
        entityId: 'ev-1',
        op: op,
        payload: payload,
        deviceId: 'peer-device',
      );

  test(
      'push: entity_type calendar_event, wire key "end", NO google_* and NO '
      'capture_fingerprint; a confirmed push marks the row clean', () async {
    final CalendarEventRow added = await addDentist();
    client.pushResults = <PushResult>[
      PushResult(
        entityId: added.id,
        entityType: 'calendar_event',
        seq: 41,
        applied: true,
      ),
    ];

    await build().syncNow();

    final Map<String, dynamic> pushed = client.pushedChanges!
        .singleWhere((chg) => chg['entity_type'] == 'calendar_event');
    expect(pushed['entity_id'], 'ev-1');
    expect(pushed['op'], 'upsert');
    final Map<String, dynamic> payload =
        pushed['payload'] as Map<String, dynamic>;
    expect(payload['title'], 'Dentist');
    expect(payload['end'], '2026-10-01T15:00:00');
    expect(payload['all_day'], 0);
    expect(payload['needs_date'], 0);
    expect(payload['time_zone'], 'America/New_York');
    expect(payload.keys, isNot(contains('end_')));
    expect(payload.keys, isNot(contains('google_event_id')));
    expect(payload.keys, isNot(contains('google_html_link')));
    expect(payload.keys, isNot(contains('google_updated')));
    expect(payload.keys, isNot(contains('capture_fingerprint')));

    final CalendarEventRow after = (await db.getCalendarEventRow('ev-1'))!;
    expect(after.syncDirty, isFalse);
    expect(after.syncedSeq, 41);
  });

  test('pull: google_* land on the row and the local fingerprint survives',
      () async {
    await addDentist();
    // Pretend the push already confirmed so the row is clean.
    await db.markCalendarEventSynced(
      'ev-1',
      seq: 1,
      pushedUpdatedAt: (await db.getCalendarEventRow('ev-1'))!.updatedAt,
    );
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[change(payload: remotePayload())],
        headSeq: 5,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    final CalendarEventRow row = (await db.getCalendarEventRow('ev-1'))!;
    expect(row.googleEventId, 'g1');
    expect(row.googleHtmlLink, 'https://calendar.google.com/event?eid=g1');
    expect(row.googleUpdated, '2026-09-28T21:00:00.000Z');
    expect(row.captureFingerprint, 'fp-1', reason: 'local-only, never pulled');
    expect(row.syncDirty, isFalse, reason: 'server content must not echo');
  });

  test('pull: Google moved the date → start changes and needs_date clears',
      () async {
    await repo.add(
      title: 'Renew passport',
      start: '2026-09-28',
      end: '2026-09-29',
      allDay: true,
      timeZone: 'America/New_York',
      needsDate: true,
      sourceRef: 'dump-1',
    );
    await db.markCalendarEventSynced(
      'ev-1',
      seq: 1,
      pushedUpdatedAt: (await db.getCalendarEventRow('ev-1'))!.updatedAt,
    );
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          change(payload: remotePayload(start: '2026-10-05', needsDate: 0)),
        ],
        headSeq: 5,
        hasMore: false,
      ),
    ];

    await build().syncNow();

    final CalendarEventRow row = (await db.getCalendarEventRow('ev-1'))!;
    expect(row.start, '2026-10-05');
    expect(row.needsDate, isFalse);
  });

  test('own-echo: a dirty local row ignores an incoming copy', () async {
    await addDentist(); // still dirty
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[change(payload: remotePayload(title: 'Peer'))],
        headSeq: 5,
        hasMore: false,
      ),
    ];
    // No push results → the row stays dirty through the cycle.
    await build().syncNow();
    final CalendarEventRow row = (await db.getCalendarEventRow('ev-1'))!;
    expect(row.title, 'Dentist');
    expect(row.googleEventId, isNull);
  });

  test('newer-wins: a stale peer update cannot roll back a clean local row',
      () async {
    await addDentist();
    final CalendarEventRow local = (await db.getCalendarEventRow('ev-1'))!;
    await db.markCalendarEventSynced(
      'ev-1',
      seq: 1,
      pushedUpdatedAt: local.updatedAt,
    );
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[
          change(
            payload: remotePayload(
              title: 'Old',
              updatedAt: '2000-01-01T00:00:00.000Z',
            ),
          ),
        ],
        headSeq: 5,
        hasMore: false,
      ),
    ];
    await build().syncNow();
    expect((await db.getCalendarEventRow('ev-1'))!.title, 'Dentist');
  });

  test('a remote row this device never saw is created clean', () async {
    client.pullPages = <SyncPullPage>[
      SyncPullPage(
        changes: <RemoteChange>[change(payload: remotePayload())],
        headSeq: 5,
        hasMore: false,
      ),
    ];
    await build().syncNow();
    final CalendarEventRow row = (await db.getCalendarEventRow('ev-1'))!;
    expect(row.title, 'Dentist');
    expect(row.allDay, isFalse);
    expect(row.syncDirty, isFalse);
    expect(row.googleEventId, 'g1');
  });

  test('Undo pushes the soft delete as a deleted_at upsert', () async {
    await addDentist();
    await repo.softDeleteFromSource('dump-1');
    await build().syncNow();
    final Map<String, dynamic> pushed = client.pushedChanges!
        .singleWhere((chg) => chg['entity_type'] == 'calendar_event');
    expect(pushed['op'], 'upsert');
    expect(
      (pushed['payload'] as Map<String, dynamic>)['deleted_at'],
      isNotNull,
    );
  });
}

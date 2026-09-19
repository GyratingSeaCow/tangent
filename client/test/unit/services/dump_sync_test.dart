// SPDX-License-Identifier: AGPL-3.0-or-later
/// Recording (dump) sync, as the database and the wire actually see it.
///
/// Jeff's defect report was that only notebooks synced. The client half of
/// that bug was one line — `if (change.entityType != 'notebook') return
/// false;` — which silently discarded every incoming recording. Nothing
/// caught it because no test had ever handed the engine a dump change.
///
/// The rules pinned here are the ones that lose user data when broken:
/// a remote row must not claim to own audio this device does not have, and
/// applying a peer's metadata must not touch the local audio path.
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
  _ScriptedClient({this.incoming = const <RemoteChange>[]});

  final List<RemoteChange> incoming;
  final List<Map<String, dynamic>> pushed = <Map<String, dynamic>>[];
  bool _drained = false;

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
    if (_drained) {
      return const SyncPullPage(changes: [], headSeq: 0, hasMore: false);
    }
    _drained = true;
    return SyncPullPage(
      changes: incoming,
      headSeq: incoming.isEmpty ? 0 : incoming.last.seq,
      hasMore: false,
    );
  }

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async {
    pushed.addAll(changes);
    return <PushResult>[
      for (final Map<String, dynamic> c in changes)
        PushResult(
          entityId: c['entity_id'] as String,
          entityType: c['entity_type'] as String,
          seq: 99,
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

RemoteChange dumpChange({
  required String id,
  int seq = 1,
  String title = 'From the tablet',
  String? transcript,
  String? meetingNotes,
  String mode = 'brain_dump',
  int durationSeconds = 12,
  bool audioKept = true,
  int? updatedAt,
  SyncOp op = SyncOp.upsert,
}) {
  final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return RemoteChange(
    seq: seq,
    entityType: 'dump',
    entityId: id,
    op: op,
    deviceId: 'the-other-device',
    payload: op == SyncOp.delete
        ? null
        : <String, dynamic>{
            'mode': mode,
            'title': title,
            'transcript': transcript,
            'meeting_notes': meetingNotes,
            'duration_seconds': durationSeconds,
            'audio_kept': audioKept,
            'created_at': now,
            'updated_at': updatedAt ?? now,
          },
  );
}

void main() {
  late LocalDb db;

  setUp(() => db = LocalDb.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  DocumentSyncEngine build(_ScriptedClient client) => DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'SM-X520',
        newDeviceId: 'device-under-test',
      );

  Future<DumpRow> seedLocal(
    String id, {
    String title = 'Local recording',
    String? audioPath,
    bool dirty = false,
  }) async {
    final String path = audioPath ?? '/storage/emulated/0/Tangent/\$id.opus';
    await db.into(db.dumps).insert(
          DumpsCompanion.insert(
            id: id,
            createdAt: DateTime.utc(2026, 9, 18, 12),
            updatedAt: DateTime.utc(2026, 9, 18, 12),
            mode: 'brain_dump',
            durationSeconds: 30,
            title: title,
            audioPath: path,
            audioSizeBytes: 4096,
            syncStatus: 'pending',
            syncDirty: Value<bool?>(dirty),
          ),
        );
    return (await db.getDumpRow(id))!;
  }

  group('incoming recordings', () {
    test('a recording from another device arrives in the list', () async {
      final client = _ScriptedClient(
        incoming: <RemoteChange>[dumpChange(id: 'dump-remote-1')],
      );

      await build(client).syncNow();

      final DumpRow? row = await db.getDumpRow('dump-remote-1');
      expect(row, isNotNull, reason: 'this is the whole defect report');
      expect(row!.title, 'From the tablet');
      expect(row.durationSeconds, 12);
    });

    test('a remote recording never claims local audio it does not have',
        () async {
      final client = _ScriptedClient(
        incoming: <RemoteChange>[dumpChange(id: 'dump-remote-2')],
      );

      await build(client).syncNow();

      final DumpRow row = (await db.getDumpRow('dump-remote-2'))!;
      // Naming a file this device does not hold produces a playback error
      // instead of an honest "download from server" affordance.
      expect(row.audioPath, isEmpty);
      expect(row.audioSizeBytes, 0);
      expect(row.remoteOnly, isTrue);
      expect(
        row.audioOnServer,
        isTrue,
        reason: 'the server has the bytes, so a download can be offered',
      );
    });

    test('audio_kept false means no download is offered', () async {
      final client = _ScriptedClient(
        incoming: <RemoteChange>[
          dumpChange(id: 'dump-remote-3', audioKept: false),
        ],
      );

      await build(client).syncNow();

      expect((await db.getDumpRow('dump-remote-3'))!.audioOnServer, isFalse);
    });

    test('transcript and meeting notes travel with the recording', () async {
      final client = _ScriptedClient(
        incoming: <RemoteChange>[
          dumpChange(
            id: 'dump-remote-4',
            mode: 'meeting',
            transcript: 'we agreed to ship it',
            meetingNotes: 'action: ship it',
          ),
        ],
      );

      await build(client).syncNow();

      final DumpRow row = (await db.getDumpRow('dump-remote-4'))!;
      expect(row.transcript, 'we agreed to ship it');
      expect(row.meetingNotes, 'action: ship it');
      expect(row.mode, 'meeting');
    });

    test('a synced transcript is shown as transcribed, not "not transcribed"',
        () async {
      // Found on hardware: 37 recordings arrived on the Fold carrying real
      // transcript text (up to 703 chars, matching the server) while the list
      // still showed "Not transcribed", because the insert never set the
      // status column and it defaulted to not_transcribed.
      final client = _ScriptedClient(
        incoming: <RemoteChange>[
          dumpChange(id: 'dump-remote-6', transcript: 'real words from server'),
        ],
      );

      await build(client).syncNow();

      final DumpRow row = (await db.getDumpRow('dump-remote-6'))!;
      expect(row.transcript, 'real words from server');
      expect(row.transcriptionStatus, 'completed');
    });

    test('a recording with no transcript keeps its untranscribed status',
        () async {
      final client = _ScriptedClient(
        incoming: <RemoteChange>[dumpChange(id: 'dump-remote-7')],
      );

      await build(client).syncNow();

      final DumpRow row = (await db.getDumpRow('dump-remote-7'))!;
      expect(row.transcriptionStatus, 'not_transcribed');
    });

    test('applying a peer edit never touches this device audio path', () async {
      final DumpRow before = await seedLocal('dump-shared-1');
      final client = _ScriptedClient(
        incoming: <RemoteChange>[
          dumpChange(id: 'dump-shared-1', title: 'Renamed on the tablet'),
        ],
      );

      await build(client).syncNow();

      final DumpRow after = (await db.getDumpRow('dump-shared-1'))!;
      expect(after.title, 'Renamed on the tablet');
      // The local file is this device's own property. A whole-row replace
      // here is how a local recording loses its own audio.
      expect(after.audioPath, before.audioPath);
      expect(after.audioSizeBytes, before.audioSizeBytes);
      expect(after.remoteOnly, isNot(true));
    });

    test('an unpushed local edit is not overwritten by a peer', () async {
      await seedLocal('dump-shared-2', title: 'My newer title', dirty: true);
      final client = _ScriptedClient(
        incoming: <RemoteChange>[
          dumpChange(id: 'dump-shared-2', title: 'Stale peer title'),
        ],
      );

      await build(client).syncNow();

      final DumpRow row = (await db.getDumpRow('dump-shared-2'))!;
      expect(
        row.title,
        'My newer title',
        reason: 'a pending local edit must never be silently discarded',
      );
      // The same cycle pushes that edit up, so by the end it is legitimately
      // clean — the guarantee is that OUR title won and left the device, not
      // that the flag is still set.
      final Map<String, dynamic>? sent = client.pushed
          .where((c) => c['entity_id'] == 'dump-shared-2')
          .firstOrNull;
      expect(sent, isNotNull);
      expect(
        (sent!['payload'] as Map<String, dynamic>)['title'],
        'My newer title',
      );
    });

    test('a peer deletion removes the recording', () async {
      await seedLocal('dump-shared-3');
      final client = _ScriptedClient(
        incoming: <RemoteChange>[
          dumpChange(id: 'dump-shared-3', op: SyncOp.delete),
        ],
      );

      await build(client).syncNow();

      expect(await db.getDumpRow('dump-shared-3'), isNull);
    });
  });

  group('outgoing recordings', () {
    test('a dirty recording is pushed', () async {
      await seedLocal('dump-mine-1', title: 'Push me', dirty: true);
      final client = _ScriptedClient();

      await build(client).syncNow();

      final Map<String, dynamic>? sent = client.pushed
          .where((c) => c['entity_id'] == 'dump-mine-1')
          .firstOrNull;
      expect(sent, isNotNull, reason: 'dirty recordings must leave the device');
      expect(sent!['entity_type'], 'dump');
      final payload = sent['payload'] as Map<String, dynamic>;
      expect(payload['title'], 'Push me');
      // Whether the SERVER holds the audio is the server's own fact. Sending
      // our view of it lets a device that never uploaded clear the flag.
      expect(payload.containsKey('audio_kept'), isFalse);
    });

    test('an accepted push clears the dirty flag', () async {
      await seedLocal('dump-mine-2', dirty: true);
      final client = _ScriptedClient();

      await build(client).syncNow();

      final DumpRow row = (await db.getDumpRow('dump-mine-2'))!;
      expect(
        row.syncDirty,
        isNot(true),
        reason: 'an accepted dump must not re-push on every cycle forever',
      );
      expect(row.syncedSeq, 99);
    });

    test('a clean recording is not pushed', () async {
      await seedLocal('dump-mine-3');
      final client = _ScriptedClient();

      await build(client).syncNow();

      expect(
        client.pushed.where((c) => c['entity_id'] == 'dump-mine-3'),
        isEmpty,
      );
    });

    test('a remote-only recording is never pushed back', () async {
      final client = _ScriptedClient(
        incoming: <RemoteChange>[dumpChange(id: 'dump-remote-5')],
      );
      await build(client).syncNow();

      // Second cycle: the row exists locally now, but this device holds no
      // authoritative copy of it. Pushing would echo the peer's own change.
      final client2 = _ScriptedClient();
      await build(client2).syncNow();

      expect(
        client2.pushed.where((c) => c['entity_id'] == 'dump-remote-5'),
        isEmpty,
      );
    });
  });

  group('local edits mark the row dirty', () {
    test('markDumpDirty queues a clean recording for the next push', () async {
      await seedLocal('dump-edit-1');
      expect((await db.getDumpRow('dump-edit-1'))!.syncDirty, isNot(true));

      await db.markDumpDirty('dump-edit-1');

      final DumpRow row = (await db.getDumpRow('dump-edit-1'))!;
      expect(row.syncDirty, isTrue);
      // And it is now visible to the push query, which is the part that
      // actually moves the edit off the device.
      final List<DumpRow> queued = await db.dumpsNeedingMetadataPush();
      expect(queued.map((r) => r.id), contains('dump-edit-1'));
    });

    test('a dirty flag survives until the server accepts it', () async {
      await seedLocal('dump-edit-2', dirty: true);

      // Wrong updated_at: the row was edited again while the push was in
      // flight, so clearing the flag here would strand that newer edit.
      await db.markDumpSynced(
        'dump-edit-2',
        seq: 7,
        pushedUpdatedAt: DateTime.utc(2000),
      );

      expect((await db.getDumpRow('dump-edit-2'))!.syncDirty, isTrue);
    });
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// Device registration, as the server actually sees it.
///
/// The first version of this shipped reading Platform.environment for the
/// Android model, which is always empty on Android, so BOTH physical devices
/// registered as the literal string "Android device" and the server's device
/// list could not tell the tablet from the phone. Unit tests passed the whole
/// time because nothing ever constructed the engine and watched what it sent.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _RecordingClient implements TranscriptionClient {
  String? registeredName;
  String? registeredId;

  /// What the engine pushed on the last cycle, verbatim.
  List<Map<String, dynamic>>? pushedChanges;

  /// Scripted push acknowledgements; empty means "accept nothing".
  List<PushResult> pushResults = const <PushResult>[];

  /// Scripted pull pages, consumed one per pullChanges call. When the list
  /// runs dry an empty page comes back — pull loops must terminate.
  List<SyncPullPage> pullPages = <SyncPullPage>[];

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    registeredId = deviceId;
    registeredName = displayName;
  }

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
  // Returns a real ConnectivityStatus, not a bare bool: noSuchMethod would
  // happily hand back the wrong type and the engine would treat this device
  // as offline, making every test in this file pass for the wrong reason.
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

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    client = _RecordingClient();
  });

  tearDown(() async => db.close());

  DocumentSyncEngine build({required Future<String> Function() label}) =>
      DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: label,
        newDeviceId: 'device-under-test',
      );

  test('the label the platform reports is what the server is told', () async {
    final DocumentSyncEngine engine = build(label: () async => 'SM-X520');

    await engine.syncNow();

    expect(
      client.registeredName,
      'SM-X520',
      reason: 'the server device list must name real hardware',
    );
    expect(client.registeredId, 'device-under-test');
  });

  test('a device that cannot name itself still syncs', () async {
    // A naming failure is cosmetic. Letting it abort the cycle would turn a
    // trivial problem into no sync at all.
    final DocumentSyncEngine engine = build(
      label: () async => throw StateError('platform channel unavailable'),
    );

    final SyncReport report = await engine.syncNow();

    expect(report.outcome, isNot(SyncOutcome.failed));
  });

  test('identity is minted once and then reused', () async {
    final DocumentSyncEngine engine = build(label: () async => 'SM-X520');

    await engine.syncNow();
    final String? first = client.registeredId;
    client.registeredId = null;
    await engine.syncNow();

    // Second cycle reuses the stored identity rather than minting a new one,
    // or every sync would add another phantom device to the server's list.
    expect(client.registeredId ?? first, first);
    final SyncStateRow state = await db.syncState(newDeviceId: 'unused');
    expect(state.deviceId, first);
  });

  group('folder sync', () {
    test('a local folder pushes (before its notebooks) and marks synced',
        () async {
      final String folderId = await db.createFolder(name: 'Field Notes');
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-1',
              title: 'Filed',
              createdAt: 1,
              updatedAt: 2,
              docJson: '{}',
              inkJson: '{}',
              folderId: Value<String?>(folderId),
            ),
          );
      client.pushResults = <PushResult>[
        PushResult(
          entityId: folderId,
          entityType: 'folder',
          seq: 5,
          applied: true,
        ),
        const PushResult(
          entityId: 'nb-1',
          entityType: 'notebook',
          seq: 6,
          applied: true,
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');

      await engine.syncNow();

      final List<Map<String, dynamic>> pushed = client.pushedChanges!;
      final int folderIndex =
          pushed.indexWhere((c) => c['entity_type'] == 'folder');
      final int notebookIndex =
          pushed.indexWhere((c) => c['entity_type'] == 'notebook');
      expect(folderIndex, isNot(-1), reason: 'the folder must push');
      expect(
        folderIndex < notebookIndex,
        isTrue,
        reason: 'folder before notebook, so the filing reference resolves',
      );
      expect(pushed[folderIndex]['payload']['name'], 'Field Notes');
      expect(
        pushed[notebookIndex]['payload']['folder_id'],
        folderId,
        reason: 'filing travels with the notebook',
      );
      expect(
        await db.foldersNeedingPush(),
        isEmpty,
        reason: 'accepted folder is clean',
      );
    });

    test('a pulled folder lands clean and a pulled deletion unfiles', () async {
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'folder',
              entityId: 'folder-remote',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'name': 'From the tablet',
                'created_at': 7,
              },
              seq: 9,
              deviceId: 'peer-device',
            ),
          ],
          headSeq: 9,
          hasMore: false,
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');
      await engine.syncNow();

      final Folder? arrived = await (db.select(db.folders)
            ..where((t) => t.id.equals('folder-remote')))
          .getSingleOrNull();
      expect(arrived, isNotNull);
      expect(arrived!.name, 'From the tablet');
      expect(
        arrived.syncDirty,
        isFalse,
        reason: 'echoing a pulled folder back would loop forever',
      );

      // Now its deletion arrives. Contents must unfile, not vanish.
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-filed',
              title: 'Inside',
              createdAt: 1,
              updatedAt: 2,
              docJson: '{}',
              inkJson: '{}',
              folderId: const Value<String?>('folder-remote'),
              syncDirty: const Value(false),
            ),
          );
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'folder',
              entityId: 'folder-remote',
              op: SyncOp.delete,
              payload: null,
              seq: 10,
              deviceId: 'peer-device',
            ),
          ],
          headSeq: 10,
          hasMore: false,
        ),
      ];
      await engine.syncNow();

      expect(
        await (db.select(db.folders)
              ..where((t) => t.id.equals('folder-remote')))
            .getSingleOrNull(),
        isNull,
      );
      final NotebookRow inside = await (db.select(db.notebooks)
            ..where((t) => t.id.equals('nb-filed')))
          .getSingle();
      expect(inside.folderId, isNull, reason: 'unfiled, never deleted');
      expect(
        inside.syncDirty,
        isFalse,
        reason: 'the deleting peer already pushed the unfilings — '
            're-pushing ours would echo',
      );
    });

    test('a pulled notebook carries its filing; an older peer keeps ours',
        () async {
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'notebook',
              entityId: 'nb-x',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Filed remotely',
                'created_at': 1,
                'updated_at': 100,
                'doc': '{}',
                'ink': '{}',
                'folder_id': 'folder-abc',
              },
              seq: 11,
              deviceId: 'peer-device',
            ),
          ],
          headSeq: 11,
          hasMore: false,
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');
      await engine.syncNow();
      NotebookRow row = await (db.select(db.notebooks)
            ..where((t) => t.id.equals('nb-x')))
          .getSingle();
      expect(row.folderId, 'folder-abc');

      // An older peer edits the same notebook: payload has NO folder_id key.
      // Absence must preserve the filing, not erase it.
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'notebook',
              entityId: 'nb-x',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Edited on an old build',
                'created_at': 1,
                'updated_at': 200,
                'doc': '{}',
                'ink': '{}',
              },
              seq: 12,
              deviceId: 'peer-device',
            ),
          ],
          headSeq: 12,
          hasMore: false,
        ),
      ];
      await engine.syncNow();
      row = await (db.select(db.notebooks)..where((t) => t.id.equals('nb-x')))
          .getSingle();
      expect(row.title, 'Edited on an old build');
      expect(
        row.folderId,
        'folder-abc',
        reason: 'an older client is a narrower payload, not an eraser',
      );
    });
  });
}

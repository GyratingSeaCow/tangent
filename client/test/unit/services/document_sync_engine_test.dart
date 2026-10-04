// SPDX-License-Identifier: AGPL-3.0-or-later
/// Device registration, as the server actually sees it.
///
/// The first version of this shipped reading Platform.environment for the
/// Android model, which is always empty on Android, so BOTH physical devices
/// registered as the literal string "Android device" and the server's device
/// list could not tell the tablet from the phone. Unit tests passed the whole
/// time because nothing ever constructed the engine and watched what it sent.
library;

import 'dart:convert';

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

  test(
    'notebook verifier sync authenticates clear and carries tombstone',
    () async {
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'protected-local',
              title: 'Private',
              createdAt: 1,
              updatedAt: 2,
              docJson: '{"blocks":[]}',
              inkJson: '{"strokes":[]}',
              passwordHash: const Value<String?>('hash-local'),
              passwordSalt: const Value<String?>('salt-local'),
              passwordIterations: const Value<int?>(210000),
            ),
          );
      client.pushResults = const <PushResult>[
        PushResult(
          entityId: 'protected-local',
          entityType: 'notebook',
          seq: 1,
          applied: true,
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');

      await engine.syncNow();

      final Map<String, dynamic> pushed = client.pushedChanges!.singleWhere(
        (Map<String, dynamic> row) => row['entity_id'] == 'protected-local',
      );
      expect(pushed['payload']['password_hash'], 'hash-local');
      expect(pushed['payload']['password_salt'], 'salt-local');
      expect(pushed['payload']['password_iterations'], 210000);
      expect(pushed['payload']['password_hash_prev'], isNull);

      client
        ..pushResults = const <PushResult>[]
        ..pullPages = <SyncPullPage>[
          const SyncPullPage(
            changes: <RemoteChange>[
              RemoteChange(
                entityType: 'notebook',
                entityId: 'protected-local',
                op: SyncOp.upsert,
                payload: <String, dynamic>{
                  'title': 'Edited by older peer',
                  'created_at': 1,
                  'updated_at': 3,
                  'doc': '{"blocks":[]}',
                  'ink': '{"strokes":[]}',
                },
                seq: 2,
                deviceId: 'old-peer',
              ),
              RemoteChange(
                entityType: 'notebook',
                entityId: 'protected-remote',
                op: SyncOp.upsert,
                payload: <String, dynamic>{
                  'title': 'Remote private',
                  'created_at': 1,
                  'updated_at': 3,
                  'doc': '{"blocks":[]}',
                  'ink': '{"strokes":[]}',
                  'password_hash': 'hash-remote',
                  'password_salt': 'salt-remote',
                  'password_iterations': 220000,
                },
                seq: 3,
                deviceId: 'new-peer',
              ),
            ],
            headSeq: 3,
            hasMore: false,
          ),
        ];
      await engine.syncNow();

      NotebookRow local = await (db.select(
        db.notebooks,
      )..where((row) => row.id.equals('protected-local')))
          .getSingle();
      expect(local.passwordHash, 'hash-local');
      expect(local.passwordSalt, 'salt-local');
      expect(local.passwordIterations, 210000);
      final NotebookRow remote = await (db.select(
        db.notebooks,
      )..where((row) => row.id.equals('protected-remote')))
          .getSingle();
      expect(remote.passwordHash, 'hash-remote');
      expect(remote.passwordSalt, 'salt-remote');
      expect(remote.passwordIterations, 220000);

      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'notebook',
              entityId: 'protected-local',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Unauthenticated clear',
                'created_at': 1,
                'updated_at': 4,
                'doc': '{"blocks":[]}',
                'ink': '{"strokes":[]}',
                'password_hash': null,
                'password_salt': null,
                'password_iterations': null,
              },
              seq: 4,
              deviceId: 'new-peer',
            ),
          ],
          headSeq: 4,
          hasMore: false,
        ),
      ];
      await engine.syncNow();
      local = await (db.select(
        db.notebooks,
      )..where((row) => row.id.equals('protected-local')))
          .getSingle();
      expect(local.passwordHash, 'hash-local');
      expect(local.passwordSalt, 'salt-local');
      expect(local.passwordIterations, 210000);

      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'notebook',
              entityId: 'protected-local',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Authenticated clear',
                'created_at': 1,
                'updated_at': 5,
                'doc': '{"blocks":[]}',
                'ink': '{"strokes":[]}',
                'password_hash': null,
                'password_salt': null,
                'password_iterations': null,
                'password_hash_prev': 'hash-local',
              },
              seq: 5,
              deviceId: 'new-peer',
            ),
          ],
          headSeq: 5,
          hasMore: false,
        ),
      ];
      await engine.syncNow();
      local = await (db.select(
        db.notebooks,
      )..where((row) => row.id.equals('protected-local')))
          .getSingle();
      expect(local.passwordHash, isNull);
      expect(local.passwordSalt, isNull);
      expect(local.passwordIterations, isNull);
      expect(local.passwordHashPrev, 'hash-local');

      // An unprotected current peer states all three nulls explicitly so the
      // server and every other current peer clear their held verifier.
      await (db.update(
        db.notebooks,
      )..where((row) => row.id.equals('protected-local')))
          .write(
        const NotebooksCompanion(
          passwordHash: Value<String?>(null),
          passwordSalt: Value<String?>(null),
          passwordIterations: Value<int?>(null),
          syncDirty: Value<bool>(true),
        ),
      );
      client
        ..pullPages = const <SyncPullPage>[]
        ..pushResults = const <PushResult>[
          PushResult(
            entityId: 'protected-local',
            entityType: 'notebook',
            seq: 5,
            applied: true,
          ),
        ];
      await engine.syncNow();
      final Map<String, dynamic> unprotectedPush =
          client.pushedChanges!.singleWhere(
        (Map<String, dynamic> row) => row['entity_id'] == 'protected-local',
      );
      expect(unprotectedPush['payload']['password_hash'], isNull);
      expect(unprotectedPush['payload']['password_salt'], isNull);
      expect(unprotectedPush['payload']['password_iterations'], isNull);
      expect(unprotectedPush['payload']['password_hash_prev'], 'hash-local');

      // The first peer can protect the notebook again after observing the
      // remote clear; the new bounded tuple is sent in full.
      await (db.update(
        db.notebooks,
      )..where((row) => row.id.equals('protected-local')))
          .write(
        const NotebooksCompanion(
          passwordHash: Value<String?>('hash-relocked'),
          passwordSalt: Value<String?>('salt-relocked'),
          passwordIterations: Value<int?>(230000),
          syncDirty: Value<bool>(true),
        ),
      );
      client.pushResults = const <PushResult>[
        PushResult(
          entityId: 'protected-local',
          entityType: 'notebook',
          seq: 6,
          applied: true,
        ),
      ];
      await engine.syncNow();
      final Map<String, dynamic> relockedPush =
          client.pushedChanges!.singleWhere(
        (Map<String, dynamic> row) => row['entity_id'] == 'protected-local',
      );
      expect(relockedPush['payload']['password_hash'], 'hash-relocked');
      expect(relockedPush['payload']['password_salt'], 'salt-relocked');
      expect(relockedPush['payload']['password_iterations'], 230000);
      expect(relockedPush['payload']['password_hash_prev'], 'hash-local');
    },
  );

  test(
    'first-seen notebook keeps a predecessor-bearing verifier tuple',
    () async {
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'notebook',
              entityId: 'rotated-first-seen',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Rotated elsewhere',
                'created_at': 1,
                'updated_at': 2,
                'doc': '{"blocks":[]}',
                'ink': '{"strokes":[]}',
                'password_hash': 'hash-current',
                'password_salt': 'salt-current',
                'password_iterations': 210000,
                'password_hash_prev': 'hash-previous',
              },
              seq: 1,
              deviceId: 'peer-device',
            ),
            RemoteChange(
              entityType: 'notebook',
              entityId: 'cleared-first-seen',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Cleared elsewhere',
                'created_at': 1,
                'updated_at': 2,
                'doc': '{"blocks":[]}',
                'ink': '{"strokes":[]}',
                'password_hash': null,
                'password_salt': null,
                'password_iterations': null,
                'password_hash_prev': 'hash-cleared',
              },
              seq: 2,
              deviceId: 'peer-device',
            ),
          ],
          headSeq: 2,
          hasMore: false,
        ),
      ];

      await build(label: () async => 'test').syncNow();

      final NotebookRow rotated =
          await db.getNotebookRow('rotated-first-seen') as NotebookRow;
      expect(
        <Object?>[
          rotated.passwordHash,
          rotated.passwordSalt,
          rotated.passwordIterations,
          rotated.passwordHashPrev,
        ],
        <Object?>['hash-current', 'salt-current', 210000, 'hash-previous'],
      );
      final NotebookRow cleared =
          await db.getNotebookRow('cleared-first-seen') as NotebookRow;
      expect(
        <Object?>[
          cleared.passwordHash,
          cleared.passwordSalt,
          cleared.passwordIterations,
          cleared.passwordHashPrev,
        ],
        <Object?>[null, null, null, 'hash-cleared'],
      );
    },
  );

  test('protected conflict fork stays protected and clean', () async {
    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: 'fork-source',
            title: 'Private',
            createdAt: 1,
            updatedAt: 5,
            docJson: '{"blocks":[]}',
            inkJson: '{"strokes":[]}',
            passwordHash: const Value<String?>('hash-old'),
            passwordSalt: const Value<String?>('salt-old'),
            passwordIterations: const Value<int?>(210000),
            syncDirty: const Value<bool>(true),
          ),
        );
    client.pullPages = <SyncPullPage>[
      const SyncPullPage(
        changes: <RemoteChange>[
          RemoteChange(
            entityType: 'notebook',
            entityId: 'fork-source',
            op: SyncOp.upsert,
            payload: <String, dynamic>{
              'title': 'Private',
              'created_at': 1,
              'updated_at': 9,
              'doc': '{"blocks":[{"kind":"text","text":"SECRET CONTENT"}]}',
              'ink': '{"strokes":[]}',
              'password_hash': 'hash-rotated',
              'password_salt': 'salt-rotated',
              'password_iterations': 210000,
              'password_hash_prev': 'hash-old',
            },
            seq: 7,
            deviceId: 'peer-device',
          ),
        ],
        headSeq: 7,
        hasMore: false,
      ),
    ];

    final SyncReport report =
        await build(label: () async => 'test').syncNow();

    final NotebookRow fork =
        await db.getNotebookRow('fork-source-conflict-7') as NotebookRow;
    expect(fork.docJson, contains('SECRET CONTENT'));
    expect(fork.passwordHash, 'hash-rotated');
    expect(fork.passwordSalt, 'salt-rotated');
    expect(fork.passwordIterations, 210000);
    expect(fork.passwordHashPrev, 'hash-old');
    expect(
      fork.syncDirty,
      isFalse,
      reason:
          'a protected conflict copy must not be pushed into server indexes',
    );
    expect(
      (await db.notebooksNeedingPush()).map((NotebookRow row) => row.id),
      isNot(contains('fork-source-conflict-7')),
    );
    expect(report.conflicts, 1);
  });

  test(
    'malformed verifier rejection surfaces error, rebases, and retries once',
    () async {
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'stale-after-clear',
              title: 'Dirty local edit',
              createdAt: 1,
              updatedAt: 5,
              docJson: '{"blocks":[{"text":"keep this edit"}]}',
              inkJson: '{"strokes":[]}',
              passwordHash: const Value<String?>('hash-old'),
              passwordSalt: const Value<String?>('salt-old'),
              passwordIterations: const Value<int?>(210000),
              syncDirty: const Value<bool>(true),
            ),
          );
      client.pushResults = const <PushResult>[
        PushResult(
          entityId: 'stale-after-clear',
          entityType: 'notebook',
          seq: 0,
          applied: false,
          reason: 'protected notebook requires sane password_iterations',
          canonicalPayload: <String, dynamic>{
            'password_hash': null,
            'password_salt': null,
            'password_iterations': null,
            'password_hash_prev': 'hash-old',
          },
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');

      final SyncReport rejected = await engine.syncNow();

      expect(rejected.outcome, SyncOutcome.failed);
      expect(rejected.pushed, 0);
      expect(rejected.error, contains('sane password_iterations'));
      expect(engine.lastError, contains('sane password_iterations'));
      NotebookRow row =
          await db.getNotebookRow('stale-after-clear') as NotebookRow;
      expect(row.docJson, contains('keep this edit'));
      expect(row.passwordHash, isNull);
      expect(row.passwordHashPrev, 'hash-old');
      expect(row.syncDirty, isTrue);

      client.pushResults = const <PushResult>[
        PushResult(
          entityId: 'stale-after-clear',
          entityType: 'notebook',
          seq: 9,
          applied: true,
        ),
      ];
      final SyncReport retried = await engine.syncNow();

      final Map<String, dynamic> retriedPayload =
          client.pushedChanges!.single['payload'] as Map<String, dynamic>;
      expect(retriedPayload['password_hash'], isNull);
      expect(retriedPayload['password_hash_prev'], 'hash-old');
      expect(retried.pushed, 1);
      row = await db.getNotebookRow('stale-after-clear') as NotebookRow;
      expect(row.syncDirty, isFalse);
    },
  );

  test(
    'malformed verifier is skipped and pull checkpoint still advances',
    () async {
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'hostile-password-metadata',
              title: 'Held private',
              createdAt: 1,
              updatedAt: 1,
              docJson: '{"blocks":[]}',
              inkJson: '{"strokes":[]}',
              passwordHash: const Value<String?>('held-hash'),
              passwordSalt: const Value<String?>('held-salt'),
              passwordIterations: const Value<int?>(210000),
              syncDirty: const Value<bool>(false),
            ),
          );
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'notebook',
              entityId: 'hostile-password-metadata',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Hostile',
                'created_at': 1,
                'updated_at': 2,
                'doc': '{"blocks":[]}',
                'ink': '{"strokes":[]}',
                'password_hash': 'hash',
                'password_salt': 'salt',
                'password_iterations': 1000001,
              },
              seq: 1,
              deviceId: 'hostile-peer',
            ),
          ],
          headSeq: 1,
          hasMore: false,
        ),
      ];

      final SyncReport report = await build(
        label: () async => 'test',
      ).syncNow();

      expect(report.outcome, SyncOutcome.success);
      final NotebookRow row = (await db.getNotebookRow(
        'hostile-password-metadata',
      ))!;
      expect(row.title, 'Hostile');
      expect(row.passwordHash, 'held-hash');
      expect(row.passwordSalt, 'held-salt');
      expect(row.passwordIterations, 210000);
      expect((await db.syncState(newDeviceId: 'unused')).lastPulledSeq, 1);
    },
  );

  group('folder sync', () {
    test(
      'a local folder pushes (before its notebooks) and marks synced',
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
        final int folderIndex = pushed.indexWhere(
          (c) => c['entity_type'] == 'folder',
        );
        final int notebookIndex = pushed.indexWhere(
          (c) => c['entity_type'] == 'notebook',
        );
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
      },
    );

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

      final Folder? arrived = await (db.select(
        db.folders,
      )..where((t) => t.id.equals('folder-remote')))
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
        await (db.select(
          db.folders,
        )..where((t) => t.id.equals('folder-remote')))
            .getSingleOrNull(),
        isNull,
      );
      final NotebookRow inside = await (db.select(
        db.notebooks,
      )..where((t) => t.id.equals('nb-filed')))
          .getSingle();
      expect(inside.folderId, isNull, reason: 'unfiled, never deleted');
      expect(
        inside.syncDirty,
        isFalse,
        reason: 'the deleting peer already pushed the unfilings — '
            're-pushing ours would echo',
      );
    });

    test(
      'a pulled notebook carries its filing; an older peer keeps ours',
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
        NotebookRow row = await (db.select(
          db.notebooks,
        )..where((t) => t.id.equals('nb-x')))
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
        row = await (db.select(
          db.notebooks,
        )..where((t) => t.id.equals('nb-x')))
            .getSingle();
        expect(row.title, 'Edited on an old build');
        expect(
          row.folderId,
          'folder-abc',
          reason: 'an older client is a narrower payload, not an eraser',
        );
      },
    );
  });

  group('pin sync', () {
    test('all pinnable entities push and pull the pin field', () async {
      await db.applyRemoteDump(
        id: 'dump-pin',
        mode: 'brain_dump',
        title: 'Recording',
        transcript: null,
        meetingNotes: null,
        durationSeconds: 3,
        audioOnServer: false,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        seq: 1,
      );
      await db.setDumpPinned('dump-pin', true, now: DateTime.utc(2026, 1, 2));
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'notebook-pin',
              title: 'Notebook',
              createdAt: 1,
              updatedAt: 2,
              docJson: '{}',
              inkJson: '{}',
              pinned: const Value<bool?>(true),
            ),
          );
      await db.into(db.todos).insert(
            TodosCompanion.insert(
              id: 'todo-pin',
              body: 'Todo',
              createdAt: '2026-01-01T00:00:00Z',
              updatedAt: '2026-01-02T00:00:00Z',
              pinned: const Value<bool?>(true),
            ),
          );
      client.pushResults = const <PushResult>[
        PushResult(
          entityId: 'dump-pin',
          entityType: 'dump',
          seq: 2,
          applied: true,
        ),
        PushResult(
          entityId: 'notebook-pin',
          entityType: 'notebook',
          seq: 3,
          applied: true,
        ),
        PushResult(
          entityId: 'todo-pin',
          entityType: 'todo',
          seq: 4,
          applied: true,
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');

      await engine.syncNow();

      for (final String type in <String>['dump', 'notebook', 'todo']) {
        final Map<String, dynamic> change = client.pushedChanges!.singleWhere(
          (Map<String, dynamic> row) => row['entity_type'] == type,
        );
        expect(change['payload']['pinned'], isTrue, reason: '$type push');
      }

      client.pushResults = const <PushResult>[];
      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'dump',
              entityId: 'dump-pin',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'mode': 'brain_dump',
                'title': 'Recording',
                'duration_seconds': 3,
                'created_at': 1767225600,
                'updated_at': 1893456000,
                'pinned': false,
              },
              seq: 10,
              deviceId: 'peer-device',
            ),
            RemoteChange(
              entityType: 'notebook',
              entityId: 'notebook-pin',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'title': 'Notebook',
                'created_at': 1,
                'updated_at': 2000000000000,
                'doc': '{}',
                'ink': '{}',
                'pinned': false,
              },
              seq: 11,
              deviceId: 'peer-device',
            ),
            RemoteChange(
              entityType: 'todo',
              entityId: 'todo-pin',
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'text': 'Todo',
                'created_at': '2026-01-01T00:00:00Z',
                'updated_at': '2030-01-01T00:00:00Z',
                'pinned': false,
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

      expect((await db.getDumpRow('dump-pin'))!.pinned, isFalse);
      expect(
        (await (db.select(
          db.notebooks,
        )..where((table) => table.id.equals('notebook-pin')))
                .getSingle())
            .pinned,
        isFalse,
      );
      expect((await db.getTodoRow('todo-pin'))!.pinned, isFalse);
    });
  });

  group('ink index sync', () {
    /// One ink_index upsert as the server builds it at pull time: the
    /// notebook's ENTIRE current index, to be applied as a replace-set.
    RemoteChange inkIndexChange({
      required String notebookId,
      required List<Map<String, dynamic>> rows,
      int seq = 20,
    }) =>
        RemoteChange(
          entityType: 'ink_index',
          entityId: notebookId,
          op: SyncOp.upsert,
          payload: <String, dynamic>{'notebook_id': notebookId, 'rows': rows},
          seq: seq,
          deviceId: 'server',
        );

    Map<String, dynamic> wordRow({
      required String id,
      required String lineId,
      required String text,
      List<num> bbox = const <num>[0, 0, 10, 10],
      List<String> strokeIds = const <String>['s1'],
    }) =>
        <String, dynamic>{
          'id': id,
          'line_id': lineId,
          'word_text': text,
          'bbox': bbox,
          'stroke_ids': strokeIds,
          'model': 'trocr-test',
          'indexed_at': 1000,
        };

    Future<List<InkIndexEntry>> rowsFor(String notebookId) => (db.select(
          db.inkIndexEntries,
        )..where((t) => t.notebookId.equals(notebookId)))
            .get();

    test(
      'a pull replaces exactly that notebook\'s rows; others untouched',
      () async {
        // Seed both notebooks with a first-generation index.
        client.pullPages = <SyncPullPage>[
          SyncPullPage(
            changes: <RemoteChange>[
              inkIndexChange(
                notebookId: 'nb-a',
                rows: <Map<String, dynamic>>[
                  wordRow(id: 'line-1:000', lineId: 'line-1', text: 'stale'),
                  wordRow(id: 'line-1:001', lineId: 'line-1', text: 'words'),
                ],
                seq: 20,
              ),
              inkIndexChange(
                notebookId: 'nb-b',
                rows: <Map<String, dynamic>>[
                  wordRow(
                    id: 'line-9:000',
                    lineId: 'line-9',
                    text: 'bystander',
                  ),
                ],
                seq: 21,
              ),
            ],
            headSeq: 21,
            hasMore: false,
          ),
        ];
        final DocumentSyncEngine engine = build(label: () async => 'test');
        await engine.syncNow();

        expect((await rowsFor('nb-a')).length, 2);
        expect((await rowsFor('nb-b')).length, 1);

        // nb-a re-indexes: the new set has ONE row and different text. The old
        // two rows must vanish — an append here would leave phantom matches for
        // words the user has since erased.
        client.pullPages = <SyncPullPage>[
          SyncPullPage(
            changes: <RemoteChange>[
              inkIndexChange(
                notebookId: 'nb-a',
                rows: <Map<String, dynamic>>[
                  wordRow(id: 'line-2:000', lineId: 'line-2', text: 'fresh'),
                ],
                seq: 22,
              ),
            ],
            headSeq: 22,
            hasMore: false,
          ),
        ];
        await engine.syncNow();

        final List<InkIndexEntry> nbA = await rowsFor('nb-a');
        expect(nbA.length, 1, reason: 'replace-set, never append');
        expect(nbA.single.wordText, 'fresh');
        expect(nbA.single.wordTextLower, 'fresh');
        expect(jsonDecode(nbA.single.strokeIdsJson), ['s1']);
        expect(
          (await rowsFor('nb-b')).single.wordText,
          'bystander',
          reason: 'another notebook\'s index must survive nb-a\'s replace-set',
        );
      },
    );

    test(
      'an index for a notebook this client has never seen inserts cleanly',
      () async {
        // The index can arrive BEFORE the notebook doc (separate change_log
        // entries, arbitrary page boundaries). Rejecting it would wedge the
        // pull loop on the same page forever.
        client.pullPages = <SyncPullPage>[
          SyncPullPage(
            changes: <RemoteChange>[
              inkIndexChange(
                notebookId: 'nb-unknown',
                rows: <Map<String, dynamic>>[
                  wordRow(id: 'line-1:000', lineId: 'line-1', text: 'early'),
                ],
                seq: 30,
              ),
            ],
            headSeq: 30,
            hasMore: false,
          ),
        ];
        final DocumentSyncEngine engine = build(label: () async => 'test');
        final SyncReport report = await engine.syncNow();

        expect(report.outcome, SyncOutcome.success);
        expect((await rowsFor('nb-unknown')).single.wordText, 'early');
      },
    );

    test(
      'mixed-case words get a locally derived lowercase search key',
      () async {
        // The wire payload carries word_text ONLY — the server never sends
        // word_text_lower; the client derives it at apply time. Every other
        // fixture word in this group is already lowercase, so only a
        // mixed-case word can prove the derivation actually happens.
        client.pullPages = <SyncPullPage>[
          SyncPullPage(
            changes: <RemoteChange>[
              inkIndexChange(
                notebookId: 'nb-case',
                rows: <Map<String, dynamic>>[
                  wordRow(id: 'line-1:000', lineId: 'line-1', text: 'Brake'),
                ],
                seq: 50,
              ),
            ],
            headSeq: 50,
            hasMore: false,
          ),
        ];
        final DocumentSyncEngine engine = build(label: () async => 'test');
        await engine.syncNow();

        final InkIndexEntry row = (await rowsFor('nb-case')).single;
        expect(row.wordText, 'Brake', reason: 'display casing must survive');
        expect(
          row.wordTextLower,
          'brake',
          reason: 'the search key is derived client-side, not taken off the '
              'wire — a case-sensitive column would hide every capitalized '
              'word from search',
        );
      },
    );

    test('an ink_index delete drops the notebook\'s rows', () async {
      client.pullPages = <SyncPullPage>[
        SyncPullPage(
          changes: <RemoteChange>[
            inkIndexChange(
              notebookId: 'nb-gone',
              rows: <Map<String, dynamic>>[
                wordRow(id: 'line-1:000', lineId: 'line-1', text: 'doomed'),
              ],
              seq: 40,
            ),
          ],
          headSeq: 40,
          hasMore: false,
        ),
      ];
      final DocumentSyncEngine engine = build(label: () async => 'test');
      await engine.syncNow();
      expect(await rowsFor('nb-gone'), isNotEmpty);

      client.pullPages = <SyncPullPage>[
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'ink_index',
              entityId: 'nb-gone',
              op: SyncOp.delete,
              payload: null,
              seq: 41,
              deviceId: 'server',
            ),
          ],
          headSeq: 41,
          hasMore: false,
        ),
      ];
      await engine.syncNow();
      expect(
        await rowsFor('nb-gone'),
        isEmpty,
        reason: 'a purged notebook\'s index must not keep matching searches',
      );
    });
  });
}

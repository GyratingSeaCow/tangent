// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

import '../../support/resolved_temp.dart';

const String _originalNotebook = 'e08adc65-2257-4a49-8d06-10b5bbdf18ff';
const String _conflictNotebook =
    'e08adc65-2257-4a49-8d06-10b5bbdf18ff-conflict-1924';
const String _sharedId = '2a52a65d3b30a84757e67b01126a85e7d2f91a8b:000';

class _RecoveryClient implements TranscriptionClient {
  _RecoveryClient(this.page);

  final SyncPullPage page;
  final List<int> requestedSince = <int>[];
  bool served = false;

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
    requestedSince.add(sinceSeq);
    if (served) {
      return SyncPullPage(
        changes: const <RemoteChange>[],
        headSeq: sinceSeq,
        hasMore: false,
      );
    }
    served = true;
    return page;
  }

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async => const <PushResult>[];

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
  test(
    'v34 collision wedge migrates, replays, and advances the checkpoint',
    () async {
      final Directory dir = createResolvedTempSync('ink-index-wedge-recovery-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file = File('${dir.path}/fixture.sqlite');

      var db = LocalDb.forTesting(NativeDatabase(file));
      await db.listDumps();
      await db.syncState(newDeviceId: 'device-recovery');
      await db.recordPullCheckpoint(1923);
      await db.customStatement(
        "INSERT INTO settings(key,value) VALUES('recovery-sentinel','preserved')",
      );
      await db
          .into(db.inkIndexEntries)
          .insert(
            InkIndexEntriesCompanion.insert(
              id: _sharedId,
              notebookId: _originalNotebook,
              lineId: 'line-original',
              wordText: 'original',
              wordTextLower: 'original',
              bboxJson: '[0,0,10,10]',
              strokeIdsJson: '["stroke-original"]',
              model: 'trocr-test',
              indexedAt: 1910,
            ),
          );
      await db.close();

      final Database old = sqlite3.open(file.path);
      old.execute(
        'ALTER TABLE ink_index_entries RENAME TO ink_index_entries_new',
      );
      old.execute('''
CREATE TABLE ink_index_entries (
  id TEXT NOT NULL PRIMARY KEY,
  notebook_id TEXT NOT NULL,
  line_id TEXT NOT NULL,
  word_text TEXT NOT NULL,
  word_text_lower TEXT NOT NULL,
  bbox_json TEXT NOT NULL,
  stroke_ids_json TEXT NOT NULL,
  model TEXT NOT NULL,
  indexed_at INTEGER NOT NULL
)
''');
      old.execute('''
INSERT INTO ink_index_entries
SELECT id, notebook_id, line_id, word_text, word_text_lower, bbox_json,
       stroke_ids_json, model, indexed_at
FROM ink_index_entries_new
''');
      old.execute('DROP TABLE ink_index_entries_new');
      old.userVersion = 34;

      expect(old.userVersion, 34);
      final List<Row> oldPk = old
          .select('PRAGMA table_info(ink_index_entries)')
          .where((Row row) => (row['pk'] as int) > 0)
          .toList();
      expect(oldPk.map((Row row) => row['name']), <Object?>['id']);

      SqliteException? collision;
      old.execute('BEGIN');
      try {
        old.execute(
          'DELETE FROM ink_index_entries WHERE notebook_id=?',
          <Object?>[_conflictNotebook],
        );
        old.execute(
          'INSERT INTO ink_index_entries VALUES(?,?,?,?,?,?,?,?,?)',
          <Object?>[
            _sharedId,
            _conflictNotebook,
            'line-conflict',
            'conflict',
            'conflict',
            '[0,0,10,10]',
            '["stroke-conflict"]',
            'trocr-test',
            1924,
          ],
        );
        old.execute('UPDATE sync_state SET last_pulled_seq=1924 WHERE id=1');
        old.execute('COMMIT');
      } on SqliteException catch (error) {
        collision = error;
        old.execute('ROLLBACK');
      }
      expect(collision?.extendedResultCode, 1555);
      expect(
        old
            .select('SELECT last_pulled_seq FROM sync_state WHERE id=1')
            .single['last_pulled_seq'],
        1923,
        reason: 'the failed page must remain pending for retry',
      );
      expect(
        old.select('SELECT notebook_id FROM ink_index_entries'),
        hasLength(1),
      );
      old.close();

      final _RecoveryClient client = _RecoveryClient(
        const SyncPullPage(
          changes: <RemoteChange>[
            RemoteChange(
              entityType: 'ink_index',
              entityId: _conflictNotebook,
              op: SyncOp.upsert,
              payload: <String, dynamic>{
                'notebook_id': _conflictNotebook,
                'rows': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': _sharedId,
                    'line_id': 'line-conflict',
                    'word_text': 'conflict',
                    'bbox': <num>[0, 0, 10, 10],
                    'stroke_ids': <String>['stroke-conflict'],
                    'model': 'trocr-test',
                    'indexed_at': 1924,
                  },
                ],
              },
              seq: 1924,
              deviceId: 'server',
            ),
          ],
          headSeq: 1924,
          hasMore: false,
        ),
      );
      db = LocalDb.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'recovery-device',
        newDeviceId: 'must-not-replace-device-recovery',
      );

      final SyncReport report = await engine.syncNow();

      expect(report.outcome, SyncOutcome.success);
      expect(client.requestedSince, <int>[1923]);
      expect((await db.syncState(newDeviceId: 'unused')).lastPulledSeq, 1924);
      final List<InkIndexEntry> rows = await db
          .select(db.inkIndexEntries)
          .get();
      expect(rows, hasLength(2));
      expect(rows.map((InkIndexEntry row) => row.id).toSet(), <String>{
        _sharedId,
      });
      expect(rows.map((InkIndexEntry row) => row.notebookId).toSet(), <String>{
        _originalNotebook,
        _conflictNotebook,
      });
      final LocalSettingRow sentinel = await (db.select(
        db.localSettings,
      )..where((table) => table.key.equals('recovery-sentinel'))).getSingle();
      expect(sentinel.value, 'preserved');

      final Database upgraded = sqlite3.open(file.path);
      addTearDown(upgraded.close);
      expect(upgraded.userVersion, 35);
      final List<Row> newPk =
          upgraded
              .select('PRAGMA table_info(ink_index_entries)')
              .where((Row row) => (row['pk'] as int) > 0)
              .toList()
            ..sort(
              (Row a, Row b) => (a['pk'] as int).compareTo(b['pk'] as int),
            );
      expect(newPk.map((Row row) => row['name']), <Object?>[
        'notebook_id',
        'id',
      ]);
    },
  );
}

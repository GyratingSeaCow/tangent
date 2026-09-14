// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_status.dart';
import 'package:tangent/services/recording_persistence.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  test('real filesystem save persists audio sidecar and valid DB row',
      () async {
    final root = await Directory.systemTemp.createTemp('tangent_pipeline_');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(root);
    final staging = File('${root.path}/pipeline.opus')
      ..writeAsBytesSync([0x4f, 0x67, 0x67, 0x53, 1], flush: true);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    final row = await RecordingPersistence(db: db, storage: storage).save(
      RecordingResult(path: staging.path, durationSeconds: 3, sizeBytes: 5),
      mode: 'brain_dump',
    );

    expect(row.title, isNotEmpty);
    expect(row.audioSizeBytes, 5);
    expect(await storage.readBytes(row.id), hasLength(5));
    expect((await db.getDump(row.id))?.title, row.title);
    expect((await storage.listAll()).single.metadata?['title'], row.title);
  });

  test('meeting recordings are private local-only from creation', () async {
    final root = await Directory.systemTemp.createTemp('tangent_meeting_');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(root);
    final staging = File('${root.path}/meeting.opus')
      ..writeAsBytesSync([0x4f, 0x67, 0x67, 0x53, 1], flush: true);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    final row = await RecordingPersistence(db: db, storage: storage).save(
      RecordingResult(path: staging.path, durationSeconds: 3, sizeBytes: 5),
      mode: 'meeting',
    );

    expect(row.syncStatus, SyncStatus.localOnly.wireValue);
    expect(
      (await storage.listAll()).single.metadata?['syncStatus'],
      SyncStatus.localOnly.wireValue,
    );
  });
}

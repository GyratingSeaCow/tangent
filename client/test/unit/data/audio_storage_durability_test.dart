// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../support/legacy_audio_storage_fixture.dart';
import '../../support/resolved_temp.dart';

void main() {
  group('durable AudioStorage filesystem contract', () {
    late Directory root;
    late AudioStorage storage;

    setUp(() async {
      root = await createResolvedTemp('tangent_durable_');
      storage = AudioStorage.test(root);
    });

    tearDown(() async => root.delete(recursive: true));

    test('persists nonempty audio and metadata before deleting staging file',
        () async {
      final staging = File('${root.path}/capture.opus');
      await staging
          .writeAsBytes([0x4f, 0x67, 0x67, 0x53, 1, 2, 3], flush: true);
      final metadata = <String, dynamic>{
        'schemaVersion': 1,
        'id': 'recording-1',
        'title': 'Original title',
        'transcript': 'Remember this',
        'durationSeconds': 7,
        'mode': 'brain_dump',
        'createdAt': '2026-09-14T12:00:00.000Z',
        'updatedAt': '2026-09-14T12:00:00.000Z',
        'syncStatus': 'pending',
        'syncAttempts': 0,
      };

      final stored = await storage.persistRecording(
        id: 'recording-1',
        temporaryPath: staging.path,
        metadata: metadata,
      );

      expect(await staging.exists(), isFalse);
      expect(stored.sizeBytes, 7);
      expect(
        await storage.readBytes('recording-1'),
        [0x4f, 0x67, 0x67, 0x53, 1, 2, 3],
      );
      final imported = await storage.listAll();
      expect(imported, hasLength(1));
      expect(imported.single.metadata, metadata);
      expect(
        jsonDecode(await storage.metaPathFor('recording-1').readAsString()),
        metadata,
      );
    });

    test('rejects empty recording and keeps staging file for recovery',
        () async {
      final staging = File('${root.path}/empty.opus');
      await staging.writeAsBytes([], flush: true);

      await expectLater(
        storage.persistRecording(
          id: 'empty',
          temporaryPath: staging.path,
          metadata: const {'id': 'empty'},
        ),
        throwsA(isA<AudioStorageException>()),
      );
      expect(await staging.exists(), isTrue);
      expect(await storage.pathFor('empty').exists(), isFalse);
    });

    test('metadata updates are imported after a simulated reinstall', () async {
      final staging = File('${root.path}/capture.opus');
      await staging.writeAsBytes([1, 2, 3], flush: true);
      await storage.persistRecording(
        id: 'recording-2',
        temporaryPath: staging.path,
        metadata: const {'id': 'recording-2', 'title': ''},
      );
      await storage.writeMetadata(
        'recording-2',
        const {'id': 'recording-2', 'title': 'Edited later'},
      );

      final afterReinstall = AudioStorage.test(root);
      final imported = await afterReinstall.listAll();
      expect(imported.single.metadata?['title'], 'Edited later');
    });
  });
}

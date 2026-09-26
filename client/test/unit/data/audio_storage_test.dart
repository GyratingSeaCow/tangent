// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../support/legacy_audio_storage_fixture.dart';
import '../../support/resolved_temp.dart';

void main() {
  group('AudioStorage', () {
    late Directory tmp;
    late AudioStorage storage;

    setUp(() async {
      tmp = await createResolvedTemp('tangent_audio_');
      storage = AudioStorage.test(tmp);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('audioDir is under app docs with "Tangent" name', () {
      expect(storage.audioDir.path, contains(tmp.path));
      expect(storage.audioDir.path, endsWith('Tangent'));
    });

    test('pathFor returns a .opus file under audioDir', () {
      final path = storage.pathFor('abc-123');
      expect(path.path, startsWith(storage.audioDir.path));
      expect(path.path, endsWith('.opus'));
    });

    test('deleteFile removes the file', () async {
      final path = storage.pathFor('abc-123');
      await path.writeAsBytes([1, 2, 3]);
      expect(await path.exists(), isTrue);
      await storage.deleteFile('abc-123');
      expect(await path.exists(), isFalse);
    });

    test('getSize returns 0 for non-existent file', () async {
      expect(await storage.getSize('does-not-exist'), 0);
    });

    test('getSize returns file size for existing file', () async {
      final path = storage.pathFor('size-test');
      await path.writeAsBytes(List.filled(100, 0));
      expect(await storage.getSize('size-test'), 100);
    });

    test('serializes same-dump metadata operations and loads queued state late',
        () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var currentTitle = 'old title';
      var activeOperations = 0;
      var maximumActiveOperations = 0;

      final first = storage.runSerializedMetadataWrite<void>(
        'serialized',
        (write) async {
          activeOperations += 1;
          maximumActiveOperations = maximumActiveOperations < activeOperations
              ? activeOperations
              : maximumActiveOperations;
          final staleSnapshot = <String, dynamic>{
            'id': 'serialized',
            'title': currentTitle,
          };
          firstStarted.complete();
          await releaseFirst.future;
          await write(staleSnapshot);
          activeOperations -= 1;
        },
      );
      await firstStarted.future;

      final second = storage.runSerializedMetadataWrite<void>(
        'serialized',
        (write) async {
          activeOperations += 1;
          maximumActiveOperations = maximumActiveOperations < activeOperations
              ? activeOperations
              : maximumActiveOperations;
          await write(<String, dynamic>{
            'id': 'serialized',
            'title': currentTitle,
          });
          activeOperations -= 1;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(activeOperations, 1);

      currentTitle = 'latest title';
      releaseFirst.complete();
      await Future.wait<void>([first, second]);

      final metadata = jsonDecode(
        await storage.metaPathFor('serialized').readAsString(),
      ) as Map<String, dynamic>;
      expect(maximumActiveOperations, 1);
      expect(metadata['title'], 'latest title');
    });
  });
}

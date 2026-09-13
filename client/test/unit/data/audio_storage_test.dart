// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';

void main() {
  group('AudioStorage', () {
    late Directory tmp;
    late AudioStorage storage;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_audio_');
      storage = AudioStorage.test(tmp);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('audioDir is under app docs with "audio" name', () {
      expect(storage.audioDir.path, contains(tmp.path));
      expect(storage.audioDir.path, endsWith('audio'));
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
  });
}
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  group('RecordingService', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangent_record_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('RecordingResult exposes duration and path', () {
      final result = RecordingResult(
        path: '${tmp.path}/test.opus',
        durationSeconds: 42,
        sizeBytes: 1024,
      );
      expect(result.durationSeconds, 42);
      expect(result.sizeBytes, 1024);
      expect(result.path, endsWith('test.opus'));
    });

    test('isRecording defaults to false', () {
      // We can't call AudioRecorder directly in tests without permissions,
      // so we test only the initial state via a constructed instance.
      // The actual recording flow requires a real device.
      final service = RecordingService.test(outputDir: tmp);
      expect(service.isRecording, isFalse);
      expect(service.currentPath, isNull);
      service.dispose();
    });
  });
}
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecordingResult', () {
    test('exposes duration, size, and path', () {
      final result = RecordingResult(
        path: '/tmp/test.opus',
        durationSeconds: 42,
        sizeBytes: 1024,
      );
      expect(result.durationSeconds, 42);
      expect(result.sizeBytes, 1024);
      expect(result.path, endsWith('test.opus'));
    });
  });

  group('StubRecordingService', () {
    test('starts not recording and with no path', () {
      final stub = StubRecordingService();
      expect(stub.isRecording, isFalse);
      expect(stub.currentPath, isNull);
    });

    test('permission always returns true', () async {
      final stub = StubRecordingService();
      expect(await stub.requestPermission(), isTrue);
      expect(stub.events, contains('permission'));
    });

    test('start sets isRecording and currentPath', () async {
      final stub = StubRecordingService();
      final path = await stub.start();
      expect(stub.isRecording, isTrue);
      expect(stub.currentPath, path);
      expect(stub.events, contains('start'));
    });

    test('stop returns null when not recording', () async {
      final stub = StubRecordingService();
      expect(await stub.stop(), isNull);
    });

    test('stop returns RecordingResult after start', () async {
      final stub = StubRecordingService();
      await stub.start();
      final result = await stub.stop();
      expect(result, isNotNull);
      expect(result!.durationSeconds, 5);
      expect(stub.isRecording, isFalse);
    });
  });
}
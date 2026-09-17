// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'package:tangent/services/recording_service.dart';

final class FileRecorder with NoInputDeviceSelection implements RecordingService {
  @override
  bool isRecording = false;
  @override
  String? currentPath;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Stream<double> amplitudeStream(Duration interval) => const Stream.empty();
  @override
  Future<String> start({required String stagingPath}) async {
    currentPath = stagingPath;
    isRecording = true;
    await File(stagingPath).writeAsBytes([1, 2, 3], flush: true);
    return stagingPath;
  }

  @override
  Future<RecordingResult?> stop() async {
    isRecording = false;
    return RecordingResult(
      path: currentPath!,
      durationSeconds: 3,
      sizeBytes: 3,
    );
  }

  @override
  Future<void> dispose() async {
    isRecording = false;
  }
}

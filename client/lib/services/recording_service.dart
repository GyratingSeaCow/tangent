// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:record/record.dart';

class RecordingResult {
  final String path;
  final int durationSeconds;
  final int sizeBytes;

  const RecordingResult({
    required this.path,
    required this.durationSeconds,
    required this.sizeBytes,
  });
}

class RecordingService {
  final AudioRecorder _recorder;
  final Directory _outputDir;
  String? _currentPath;
  DateTime? _startedAt;
  bool _isRecording = false;

  RecordingService({Directory? outputDir, AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder(),
        _outputDir = outputDir ?? Directory.systemTemp;

  RecordingService.test({required Directory outputDir, AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder(),
        _outputDir = outputDir;

  bool get isRecording => _isRecording;
  String? get currentPath => _currentPath;

  /// Request microphone permission. Returns true if granted.
  Future<bool> requestPermission() => _recorder.hasPermission();

  /// Start recording to a new file. Returns the path.
  Future<String> start() async {
    if (_isRecording) {
      throw StateError('Already recording');
    }
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }
    final path =
        '${_outputDir.path}/${DateTime.now().microsecondsSinceEpoch}.opus';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.opus,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 32000,
      ),
      path: path,
    );
    _currentPath = path;
    _startedAt = DateTime.now();
    _isRecording = true;
    return path;
  }

  /// Stop recording. Returns the result with duration and file size.
  Future<RecordingResult?> stop() async {
    if (!_isRecording) return null;
    final path = await _recorder.stop();
    _isRecording = false;
    if (path == null || _startedAt == null) {
      _currentPath = null;
      _startedAt = null;
      return null;
    }
    final duration = DateTime.now().difference(_startedAt!).inSeconds;
    final file = File(path);
    final size = await file.exists() ? await file.length() : 0;
    _currentPath = null;
    _startedAt = null;
    return RecordingResult(
      path: path,
      durationSeconds: duration,
      sizeBytes: size,
    );
  }

  Future<void> dispose() => _recorder.dispose();
}
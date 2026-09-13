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

/// Test-friendly abstraction. Production uses the default implementation;
/// tests inject a stub.
abstract class RecordingService {
  bool get isRecording;
  String? get currentPath;

  Future<bool> requestPermission();
  Future<String> start();
  Future<RecordingResult?> stop();
  Future<void> dispose();
}

class DefaultRecordingService implements RecordingService {
  AudioRecorder? _recorder;
  final Directory _outputDir;
  String? _currentPath;
  DateTime? _startedAt;
  bool _isRecording = false;

  DefaultRecordingService({Directory? outputDir, AudioRecorder? recorder})
      : _recorder = recorder,
        _outputDir = outputDir ?? Directory.systemTemp;

  AudioRecorder get _ensureRecorder => _recorder ??= AudioRecorder();

  @override
  bool get isRecording => _isRecording;

  @override
  String? get currentPath => _currentPath;

  @override
  Future<bool> requestPermission() => _ensureRecorder.hasPermission();

  @override
  Future<String> start() async {
    if (_isRecording) {
      throw StateError('Already recording');
    }
    final recorder = _ensureRecorder;
    if (!await recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }
    final path =
        '${_outputDir.path}/${DateTime.now().microsecondsSinceEpoch}.opus';
    await recorder.start(
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

  @override
  Future<RecordingResult?> stop() async {
    if (!_isRecording) return null;
    final path = await _ensureRecorder.stop();
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

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
    _recorder = null;
  }
}

/// Test-only stub: never touches platform channels.
class StubRecordingService implements RecordingService {
  bool _isRecording = false;
  String? _path;
  final List<String> events = [];

  @override
  bool get isRecording => _isRecording;
  @override
  String? get currentPath => _path;

  @override
  Future<bool> requestPermission() async {
    events.add('permission');
    return true;
  }

  @override
  Future<String> start() async {
    events.add('start');
    _isRecording = true;
    _path = '/tmp/stub.opus';
    return _path!;
  }

  @override
  Future<RecordingResult?> stop() async {
    events.add('stop');
    if (!_isRecording) return null;
    _isRecording = false;
    final p = _path!;
    _path = null;
    return RecordingResult(path: p, durationSeconds: 5, sizeBytes: 100);
  }

  @override
  Future<void> dispose() async {
    events.add('dispose');
  }
}
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
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

abstract class RecordingService {
  bool get isRecording;
  String? get currentPath;

  Future<bool> requestPermission();
  Stream<double> amplitudeStream(Duration interval);
  Future<String> start({required String stagingPath});
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
        _outputDir = outputDir ??
            (throw ArgumentError('A staging output directory is required'));

  AudioRecorder get _ensureRecorder => _recorder ??= AudioRecorder();

  @override
  bool get isRecording => _isRecording;

  @override
  String? get currentPath => _currentPath;

  @override
  Future<bool> requestPermission() => _ensureRecorder.hasPermission();

  @override
  Stream<double> amplitudeStream(Duration interval) => _ensureRecorder
      .onAmplitudeChanged(interval)
      .map((value) => value.current);

  @override
  Future<String> start({required String stagingPath}) async {
    if (_isRecording) throw StateError('Already recording');
    final recorder = _ensureRecorder;
    if (!await recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }
    if (!p.isAbsolute(stagingPath) ||
        !p.equals(p.dirname(stagingPath), _outputDir.path)) {
      throw ArgumentError('Recording requires the reserved staging path');
    }
    await _outputDir.create(recursive: true);
    final path = stagingPath;
    await File(path).create(exclusive: true);
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
    final startedAt = _startedAt;
    String? path;
    try {
      path = await _ensureRecorder.stop();
    } finally {
      _isRecording = false;
      _currentPath = null;
      _startedAt = null;
    }
    if (path == null || startedAt == null) return null;
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Recorder stopped without producing an audio file');
    }
    final size = await file.length();
    if (size <= 0) throw StateError('Recorder produced an empty audio file');
    return RecordingResult(
      path: path,
      durationSeconds: DateTime.now().difference(startedAt).inSeconds,
      sizeBytes: size,
    );
  }

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
    _recorder = null;
    _isRecording = false;
    _currentPath = null;
    _startedAt = null;
  }
}

class StubRecordingService implements RecordingService {
  bool _isRecording = false;
  String? _path;
  bool _disposed = false;
  final List<String> events = [];
  final StreamController<double> _amplitudes = StreamController.broadcast();

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
  Stream<double> amplitudeStream(Duration interval) {
    events.add('amplitude:${interval.inMilliseconds}');
    return _amplitudes.stream;
  }

  void emitAmplitude(double dbfs) => _amplitudes.add(dbfs);
  void emitAmplitudeError(Object error) => _amplitudes.addError(error);

  @override
  Future<String> start({required String stagingPath}) async {
    events.add('start');
    _isRecording = true;
    _path = stagingPath;
    return _path!;
  }

  @override
  Future<RecordingResult?> stop() async {
    events.add('stop');
    if (!_isRecording) return null;
    _isRecording = false;
    final path = _path!;
    _path = null;
    return RecordingResult(path: path, durationSeconds: 5, sizeBytes: 100);
  }

  @override
  Future<void> dispose() async {
    events.add('dispose');
    if (!_disposed) {
      _disposed = true;
      await _amplitudes.close();
    }
  }
}

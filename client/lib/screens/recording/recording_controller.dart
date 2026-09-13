// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording_service.dart';

enum RecordingState { idle, recording, saving }

class RecordingController extends StateNotifier<RecordingState> {
  final RecordingService _service;
  Timer? _timer;
  DateTime? _startedAt;

  RecordingController(this._service) : super(RecordingState.idle);

  factory RecordingController.test() {
    return RecordingController(StubRecordingService());
  }

  bool get isRecording => state == RecordingState.recording;
  int get elapsedSeconds {
    if (_startedAt == null) return 0;
    return DateTime.now().difference(_startedAt!).inSeconds;
  }

  Future<void> start() async {
    if (state != RecordingState.idle) return;
    await _service.start();
    _startedAt = DateTime.now();
    state = RecordingState.recording;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Force UI rebuild to show updated timer.
      state = RecordingState.recording;
    });
  }

  Future<RecordingResult?> stop() async {
    if (state != RecordingState.recording) return null;
    _timer?.cancel();
    _timer = null;
    state = RecordingState.saving;
    final result = await _service.stop();
    _startedAt = null;
    state = RecordingState.idle;
    return result;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _service.dispose();
    super.dispose();
  }
}

final recordingServiceProvider = Provider<RecordingService>((ref) {
  return DefaultRecordingService();
});

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>((ref) {
  return RecordingController(ref.watch(recordingServiceProvider));
});
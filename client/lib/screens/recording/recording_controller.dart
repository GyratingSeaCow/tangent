// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording_service.dart';

enum RecordingState { idle, recording, saving }

/// Tick counter incremented every second while recording. Consumers watch
/// this to update their timer display without relying on state-changed
/// events (which don't fire when the state value is the same).
final recordingTickProvider = StateProvider<int>((ref) => 0);

class RecordingController extends StateNotifier<RecordingState> {
  final RecordingService _service;
  final Ref _ref;
  Timer? _timer;
  DateTime? _startedAt;

  RecordingController(this._service, this._ref)
      : super(RecordingState.idle);

  factory RecordingController.test(Ref ref) {
    return RecordingController(StubRecordingService(), ref);
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
    _ref.read(recordingTickProvider.notifier).state = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Bump the tick counter so listeners watching recordingTickProvider
      // can re-read elapsedSeconds and rebuild. We can't just set
      // `state = RecordingState.recording` because StateNotifier suppresses
      // notifications when the value is unchanged, which leaves the UI
      // timer frozen at 00:00 even though the mic stream is alive.
      _ref.read(recordingTickProvider.notifier).state++;
    });
  }

  Future<RecordingResult?> stop() async {
    if (state != RecordingState.recording) return null;
    _timer?.cancel();
    _timer = null;
    state = RecordingState.saving;
    final result = await _service.stop();
    _startedAt = null;
    _ref.read(recordingTickProvider.notifier).state = 0;
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
  return RecordingController(
    ref.watch(recordingServiceProvider),
    ref,
  );
});
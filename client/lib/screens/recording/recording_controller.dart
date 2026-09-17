// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording_service.dart';
import '../../data/local_db.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart';
import '../../services/screen_awake.dart';
import '../home/home_providers.dart';
import '../settings/settings_screen.dart';
import 'waveform_state.dart';

enum RecordingState { idle, starting, recording, saving }

final recordingTickProvider = StateProvider<int>((ref) => 0);

class RecordingController extends StateNotifier<RecordingState> {
  final RecordingService _service;
  final RecordingCoordinator Function() _coordinator;
  final Future<void> Function() _ready;
  final ScreenAwake _screenAwake;
  final StateController<int> _tick;
  final WaveformNotifier _waveform;
  final bool Function() _keepAwake;
  Timer? _timer;
  StreamSubscription<double>? _amplitudeSubscription;
  DateTime? _startedAt;

  RecordingController(
    this._service,
    this._coordinator,
    this._ready,
    this._screenAwake,
    this._tick,
    this._waveform,
    this._keepAwake,
  ) : super(RecordingState.idle);

  bool get isRecording => state == RecordingState.recording;
  int get elapsedSeconds {
    if (_startedAt == null) return 0;
    return DateTime.now().difference(_startedAt!).inSeconds;
  }

  Future<void> start({required String mode}) async {
    if (state != RecordingState.idle) return;
    state = RecordingState.starting;
    _clearVisualState();
    try {
      await _ready();
      final outcome = await _coordinator().start(mode: mode);
      if (outcome case Fail(:final problem)) throw StorageFault(problem);
      _startedAt = DateTime.now();
      state = RecordingState.recording;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _tick.state++;
      });
      _amplitudeSubscription =
          _service.amplitudeStream(const Duration(milliseconds: 60)).listen(
        _waveform.addDbfs,
        onError: (_) {
          unawaited(_amplitudeSubscription?.cancel());
          _amplitudeSubscription = null;
          _waveform.clear();
        },
      );
      if (_keepAwake()) {
        try {
          await _screenAwake.setEnabled(true);
        } catch (_) {
          // Screen-awake is optional and must never terminate valid audio capture.
        }
      }
    } catch (_) {
      await _releaseRecordingUi();
      state = RecordingState.idle;
      rethrow;
    }
  }

  Future<DumpRow?> stop() async {
    if (state != RecordingState.recording) return null;
    state = RecordingState.saving;
    try {
      return switch (await _coordinator().stopAndPersist()) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem),
      };
    } finally {
      await _releaseRecordingUi();
      state = RecordingState.idle;
    }
  }

  void _clearVisualState() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
    _tick.state = 0;
    _waveform.clear();
  }

  Future<void> _releaseRecordingUi() async {
    _timer?.cancel();
    _timer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _clearVisualState();
    try {
      await _screenAwake.setEnabled(false);
    } catch (_) {
      // Native activity destruction also clears FLAG_KEEP_SCREEN_ON.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(_amplitudeSubscription?.cancel());
    _amplitudeSubscription = null;
    _waveform.clear();
    unawaited(_screenAwake.setEnabled(false).catchError((_) {}));
    unawaited(_service.dispose());
    super.dispose();
  }
}

final recordingServiceProvider = Provider<RecordingService>((ref) {
  final audio = ref.watch(audioStorageProvider);
  return DefaultRecordingService(outputDir: audio.stagingDir);
});

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>((ref) {
  return RecordingController(
    ref.watch(recordingServiceProvider),
    () => ref.read(recordingCoordinatorProvider),
    () => ref.read(captureReadyProvider.future),
    ref.watch(screenAwakeProvider),
    ref.watch(recordingTickProvider.notifier),
    ref.watch(waveformProvider.notifier),
    () => ref.read(settingsStoreProvider).keepScreenAwakeWhileRecording,
  );
});

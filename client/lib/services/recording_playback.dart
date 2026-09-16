// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../data/storage/storage_contract.dart';

@immutable
final class RecordingPlaybackState {
  const RecordingPlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.completed = false,
    this.loading = false,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool completed;
  final bool loading;
  final String? error;
}

abstract interface class RecordingPlaybackEngine {
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;

  Future<Duration?> load(AudioLocator source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

final class JustAudioRecordingPlaybackEngine
    implements RecordingPlaybackEngine {
  JustAudioRecordingPlaybackEngine({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream =>
      _player.playerStateStream.map((state) => state.playing).distinct();

  @override
  Stream<bool> get completedStream => _player.playerStateStream
      .map((state) => state.processingState == ProcessingState.completed)
      .distinct();

  @override
  Future<Duration?> load(AudioLocator source) {
    return switch (source.kind) {
      'file' => _player.setFilePath(source.value),
      'saf' => _player.setAudioSource(AudioSource.uri(Uri.parse(source.value))),
      _ => throw ArgumentError.value(source.kind, 'source.kind'),
    };
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() => _player.dispose();
}

final class RecordingPlaybackController extends ChangeNotifier {
  RecordingPlaybackController({RecordingPlaybackEngine? engine})
      : _engine = engine ?? JustAudioRecordingPlaybackEngine() {
    _subscriptions.addAll([
      _engine.positionStream.listen(_onPosition),
      _engine.durationStream.listen(_onDuration),
      _engine.playingStream.listen(_onPlaying),
      _engine.completedStream.listen(_onCompleted),
    ]);
  }

  final RecordingPlaybackEngine _engine;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  RecordingPlaybackState _state = const RecordingPlaybackState();
  bool _disposed = false;

  RecordingPlaybackState get state => _state;

  Future<void> initialize(AudioLocator source) async {
    _replace(loading: true, clearError: true);
    try {
      final duration = await _engine.load(source);
      if (_disposed) return;
      _replace(
        duration: duration ?? Duration.zero,
        loading: false,
        clearError: true,
      );
    } catch (error) {
      if (_disposed) return;
      _replace(loading: false, error: 'Playback unavailable: $error');
    }
  }

  Future<void> togglePlayback() async {
    if (_state.loading || _state.error != null) return;
    try {
      if (_state.playing) {
        await _engine.pause();
      } else {
        final atEnd = _state.duration > Duration.zero &&
            _state.position >=
                _state.duration - const Duration(milliseconds: 250);
        if (_state.completed && atEnd) {
          await seek(Duration.zero);
        }
        await _engine.play();
      }
    } catch (error) {
      if (!_disposed) _replace(error: 'Playback failed: $error');
    }
  }

  Future<void> seek(Duration requested) async {
    final end = _state.duration;
    final clamped = requested < Duration.zero
        ? Duration.zero
        : requested > end
            ? end
            : requested;
    try {
      if (!_disposed) {
        _replace(
          position: clamped,
          completed: clamped == end && end > Duration.zero,
        );
      }
      await _engine.seek(clamped);
    } catch (error) {
      if (!_disposed) _replace(error: 'Could not seek: $error');
    }
  }

  void _onPosition(Duration position) {
    if (_disposed) return;
    final end = _state.duration;
    _replace(position: position > end && end > Duration.zero ? end : position);
  }

  void _onDuration(Duration? duration) {
    if (_disposed || duration == null) return;
    _replace(duration: duration);
  }

  void _onPlaying(bool playing) {
    if (_disposed) return;
    _replace(playing: playing);
  }

  void _onCompleted(bool completed) {
    if (_disposed) return;
    _replace(completed: completed, playing: completed ? false : _state.playing);
  }

  void _replace({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? completed,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    _state = RecordingPlaybackState(
      position: position ?? _state.position,
      duration: duration ?? _state.duration,
      playing: playing ?? _state.playing,
      completed: completed ?? _state.completed,
      loading: loading ?? _state.loading,
      error: clearError ? null : error ?? _state.error,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(close());
    super.dispose();
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    await _engine.dispose();
  }
}

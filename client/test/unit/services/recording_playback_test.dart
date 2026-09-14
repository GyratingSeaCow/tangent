// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/recording_playback.dart';

void main() {
  test('loads, plays, seeks, pauses, and restarts completed audio', () async {
    final engine = _FakePlaybackEngine();
    final controller = RecordingPlaybackController(engine: engine);
    addTearDown(controller.dispose);

    await controller.initialize('content://tangent/recording.opus');
    expect(engine.loadedSource, 'content://tangent/recording.opus');
    expect(controller.state.duration, const Duration(seconds: 20));

    await controller.togglePlayback();
    expect(engine.playCount, 1);

    engine.emitPosition(const Duration(seconds: 7));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.position, const Duration(seconds: 7));

    await controller.seek(const Duration(seconds: 12));
    expect(engine.lastSeek, const Duration(seconds: 12));

    engine.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
    await controller.togglePlayback();
    expect(engine.pauseCount, 1);

    engine.emitPosition(const Duration(seconds: 20));
    engine.emitCompleted(true);
    await Future<void>.delayed(Duration.zero);
    await controller.togglePlayback();
    expect(engine.lastSeek, Duration.zero);
    expect(engine.playCount, 2);
  });

  test('playing after a backward seek ignores a stale completed event',
      () async {
    final engine = _FakePlaybackEngine();
    final controller = RecordingPlaybackController(engine: engine);
    addTearDown(controller.dispose);

    await controller.initialize('recording.opus');
    engine.emitPosition(const Duration(seconds: 20));
    engine.emitCompleted(true);
    await Future<void>.delayed(Duration.zero);

    await controller.seek(const Duration(seconds: 4));
    engine.emitCompleted(true);
    await Future<void>.delayed(Duration.zero);
    await controller.togglePlayback();

    expect(engine.lastSeek, const Duration(seconds: 4));
    expect(engine.playCount, 1);
  });

  test('clamps seeks to the recording duration', () async {
    final engine = _FakePlaybackEngine();
    final controller = RecordingPlaybackController(engine: engine);
    addTearDown(controller.dispose);

    await controller.initialize('recording.opus');
    await controller.seek(const Duration(seconds: 90));

    expect(engine.lastSeek, const Duration(seconds: 20));
  });
}

final class _FakePlaybackEngine implements RecordingPlaybackEngine {
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? loadedSource;
  Duration? lastSeek;
  int playCount = 0;
  int pauseCount = 0;

  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Future<Duration?> load(String source) async {
    loadedSource = source;
    return const Duration(seconds: 20);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    emitPlaying(false);
  }

  @override
  Future<void> play() async {
    playCount++;
    emitPlaying(true);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    emitPosition(position);
  }

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _completed.close();
  }

  void emitPosition(Duration value) => _positions.add(value);
  void emitPlaying(bool value) => _playing.add(value);
  void emitCompleted(bool value) => _completed.add(value);
}

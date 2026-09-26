// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/recording_playback.dart';

void main() {
  test('loads, plays, seeks, pauses, and restarts completed audio', () async {
    final engine = _FakePlaybackEngine();
    final controller = RecordingPlaybackController(engine: engine);
    addTearDown(controller.dispose);

    await controller.initialize(
      (kind: 'saf', value: 'content://tangent/recording.opus'),
    );
    expect(
      engine.loadedSource,
      (kind: 'saf', value: 'content://tangent/recording.opus'),
    );
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

    await controller.initialize((kind: 'file', value: 'recording.opus'));
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

  test('a seek after completion pauses first so the next play is real',
      () async {
    // just_audio keeps `playing == true` once the stream completes, and its
    // play() is a no-op while that flag is set. A word tap after the clip
    // has ended (seek + play) therefore reached mpv as a bare seek at EOF,
    // which it ignores — the transcript went dead after one listen.
    // Pausing before the seek clears the flag, so play() actually plays.
    final engine = _FakePlaybackEngine();
    final controller = RecordingPlaybackController(engine: engine);
    addTearDown(controller.dispose);

    await controller.initialize((kind: 'file', value: 'recording.opus'));
    await controller.togglePlayback();
    engine.emitPlaying(true);
    engine.emitPosition(const Duration(seconds: 20));
    engine.emitCompleted(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.playing, isFalse);

    engine.log.clear();
    await controller.seek(const Duration(seconds: 3));
    await controller.togglePlayback();
    expect(engine.log, ['pause', 'seek 0:00:03.000000', 'play']);

    // A seek while simply paused (not completed) must not add a pause.
    engine.emitCompleted(false);
    engine.emitPlaying(false);
    await Future<void>.delayed(Duration.zero);
    engine.log.clear();
    await controller.seek(const Duration(seconds: 5));
    expect(engine.log, ['seek 0:00:05.000000']);
  });

  test('clamps seeks to the recording duration', () async {
    final engine = _FakePlaybackEngine();
    final controller = RecordingPlaybackController(engine: engine);
    addTearDown(controller.dispose);

    await controller.initialize((kind: 'file', value: 'recording.opus'));
    await controller.seek(const Duration(seconds: 90));

    expect(engine.lastSeek, const Duration(seconds: 20));
  });
}

final class _FakePlaybackEngine implements RecordingPlaybackEngine {
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  AudioLocator? loadedSource;
  Duration? lastSeek;
  int playCount = 0;
  int pauseCount = 0;
  final List<String> log = <String>[];

  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Future<Duration?> load(AudioLocator source) async {
    loadedSource = source;
    return const Duration(seconds: 20);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    log.add('pause');
    emitPlaying(false);
  }

  @override
  Future<void> play() async {
    playCount++;
    log.add('play');
    emitPlaying(true);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    log.add('seek $position');
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

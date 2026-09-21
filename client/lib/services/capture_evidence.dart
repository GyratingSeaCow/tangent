// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'recording_service.dart';

/// Waits for evidence that capture is actually live before reporting started.
///
/// On Linux, record_linux's start() resolves when the `parecord` process is
/// SPAWNED, not when the mic stream is connected. PipeWire takes ~120-190ms
/// (measured on CachyOS) to open the source, so the UI flips to "recording"
/// while early audio still goes nowhere — the user's first words are cut off.
///
/// The plugin holds its amplitude at exactly -160.0 dBFS until the first real
/// PCM chunk arrives; any other reading is proof the stream is flowing. This
/// wrapper polls amplitude after delegating start, and returns once evidence
/// appears or a short deadline passes. The deadline matters: a hardware-muted
/// mic delivers literal zeros forever (amplitude stays -160.0) and recording
/// silence is legitimate — this must delay honestly, never hang.
class CaptureEvidenceRecorder implements InputAwareAudioRecorder {
  CaptureEvidenceRecorder(
    this._inner, {
    Duration pollInterval = const Duration(milliseconds: 30),
    Duration deadline = const Duration(milliseconds: 700),
  })  : _pollInterval = pollInterval,
        _deadline = deadline;

  final InputAwareAudioRecorder _inner;
  final Duration _pollInterval;
  final Duration _deadline;

  /// The exact idle sentinel record_linux reports before any PCM arrives.
  static const double _idleSentinel = -160.0;

  Future<void> _awaitCaptureEvidence() async {
    final sw = Stopwatch()..start();
    StreamSubscription<Amplitude>? sub;
    final done = Completer<void>();
    sub = _inner.onAmplitudeChanged(_pollInterval).listen(
      (amplitude) {
        if (amplitude.current != _idleSentinel && !done.isCompleted) {
          done.complete();
        }
      },
      // A platform without amplitude support must not break starting.
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(_deadline - sw.elapsed, onTimeout: () {});
    } catch (_) {
      // Evidence is best-effort; the capture itself is already running.
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    await _inner.start(config, path: path);
    await _awaitCaptureEvidence();
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    final stream = await _inner.startStream(config);
    await _awaitCaptureEvidence();
    return stream;
  }

  @override
  Future<bool> hasPermission() => _inner.hasPermission();

  @override
  Future<List<InputDevice>> listInputDevices() => _inner.listInputDevices();

  @override
  Future<String?> stop() => _inner.stop();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _inner.onAmplitudeChanged(interval);

  @override
  Future<void> dispose() => _inner.dispose();
}

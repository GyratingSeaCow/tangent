// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tangent/services/capture_evidence.dart';
import 'package:tangent/services/recording_service.dart';

/// On Linux, record_linux's start() resolves when `parecord` is SPAWNED,
/// not when the mic stream is connected — the stream comes live ~120-190ms
/// later (measured on CachyOS/PipeWire). Tangent flips the UI to
/// "recording" when start() returns, so the user's first words land in a
/// window where the screen says recording and audio goes nowhere.
///
/// The plugin's amplitude is exactly -160.0 dBFS until the first real PCM
/// chunk is processed, which is our evidence that capture is live.
/// [CaptureEvidenceRecorder.start] must not complete before that evidence
/// (or a bounded timeout for genuinely silent digital inputs).
class _FakeRecorder implements InputAwareAudioRecorder {
  _FakeRecorder({required this.evidenceAfter});

  /// How long after start() the fake begins reporting real amplitude.
  final Duration? evidenceAfter;

  DateTime? startedAt;
  int amplitudePolls = 0;

  double get _amplitudeNow {
    final at = startedAt;
    final after = evidenceAfter;
    if (at == null || after == null) return -160.0;
    return DateTime.now().difference(at) >= after ? -42.0 : -160.0;
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startedAt = DateTime.now();
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    startedAt = DateTime.now();
    return const Stream<Uint8List>.empty();
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) async* {
    while (true) {
      await Future<void>.delayed(interval);
      amplitudePolls++;
      yield Amplitude(current: _amplitudeNow, max: _amplitudeNow);
    }
  }

  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<List<InputDevice>> listInputDevices() async => const [];
  @override
  Future<String?> stop() async => null;
  @override
  Future<void> dispose() async {}
}

const _config = RecordConfig(encoder: AudioEncoder.opus);

void main() {
  test('start() holds until the mic stream shows real amplitude', () async {
    final inner =
        _FakeRecorder(evidenceAfter: const Duration(milliseconds: 150));
    final recorder = CaptureEvidenceRecorder(inner);

    final sw = Stopwatch()..start();
    await recorder.start(_config, path: '/tmp/x.opus');
    sw.stop();

    expect(
      sw.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 140)),
      reason: 'start must not report success while amplitude is still the '
          '-160.0 sentinel — the mic stream is not connected yet',
    );
    expect(
      inner.amplitudePolls,
      greaterThan(0),
      reason: 'evidence must come from the plugin, not a blind sleep',
    );
  });

  test('digital silence does not wedge start() forever', () async {
    // A hardware-muted mic delivers literal zeros: amplitude stays -160.0
    // even though capture is live. Recording silence is legitimate — the
    // wait must give up quickly and let the capture proceed.
    final inner = _FakeRecorder(evidenceAfter: null);
    final recorder = CaptureEvidenceRecorder(inner);

    final sw = Stopwatch()..start();
    await recorder.start(_config, path: '/tmp/x.opus');
    sw.stop();

    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 1)),
      reason: 'the evidence wait is bounded, never a hang',
    );
  });

  test('startStream() waits for evidence the same way', () async {
    final inner =
        _FakeRecorder(evidenceAfter: const Duration(milliseconds: 150));
    final recorder = CaptureEvidenceRecorder(inner);

    final sw = Stopwatch()..start();
    await recorder.startStream(_config);
    sw.stop();

    expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 140)));
  });

  test('delegates everything else untouched', () async {
    final inner = _FakeRecorder(evidenceAfter: null);
    final recorder = CaptureEvidenceRecorder(inner);
    expect(await recorder.hasPermission(), isTrue);
    expect(await recorder.listInputDevices(), isEmpty);
    expect(await recorder.stop(), isNull);
  });
}

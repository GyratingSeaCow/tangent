// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Amplified capture: the recorder streams raw PCM, each chunk is multiplied,
// and the result is written as a WAV file at the reserved staging path.
//
// This is the most safety-critical path in the app -- the reservation and
// crash-safety machinery lives here -- so the properties under test are the
// ones that lose recordings when they break: the file lands at the reserved
// path, the header describes the real payload, and unity gain does not touch
// the existing Opus path at all.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:tangent/services/audio_gain.dart';
import 'package:tangent/services/recording_service.dart';

/// Recorder fake that can serve both the file path and the stream path.
final class FakeStreamRecorder implements InputAwareAudioRecorder {
  FakeStreamRecorder({this.chunks = const <List<int>>[]});

  /// PCM16 chunks handed to the stream consumer.
  List<List<int>> chunks;

  final List<RecordConfig> configs = <RecordConfig>[];
  String? startedPath;
  bool streamStarted = false;
  bool fileStarted = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<List<InputDevice>> listInputDevices() async => const <InputDevice>[];

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    configs.add(config);
    startedPath = path;
    fileStarted = true;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    configs.add(config);
    streamStarted = true;
    return Stream<Uint8List>.fromIterable(
      chunks.map(Uint8List.fromList),
    );
  }

  @override
  Future<String?> stop() async => startedPath;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream<Amplitude>.empty();

  @override
  Future<void> dispose() async {}
}

/// Little-endian PCM16 bytes for [samples].
List<int> pcm(List<int> samples) {
  final ByteData data = ByteData(samples.length * 2);
  for (int i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tangent-gain-'));
  tearDown(() => dir.deleteSync(recursive: true));

  DefaultRecordingService serviceWith(
    FakeStreamRecorder recorder,
    double gain,
  ) =>
      DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        micGain: () => gain,
      );

  group('unity gain keeps the existing path', () {
    test('records opus through the file API, not the stream', () async {
      final FakeStreamRecorder recorder = FakeStreamRecorder();
      final DefaultRecordingService service =
          serviceWith(recorder, defaultMicGain);

      await service.start(stagingPath: p.join(dir.path, '1-a.opus'));

      expect(
        recorder.fileStarted,
        isTrue,
        reason: 'the default must stay on the encoded path',
      );
      expect(recorder.streamStarted, isFalse);
      expect(recorder.configs.single.encoder, AudioEncoder.opus);
    });
  });

  group('gain above unity streams PCM to a WAV file', () {
    test('asks the recorder for raw PCM', () async {
      final FakeStreamRecorder recorder = FakeStreamRecorder(
        chunks: <List<int>>[pcm(<int>[100, 200])],
      );
      final DefaultRecordingService service = serviceWith(recorder, 2.0);

      await service.start(stagingPath: p.join(dir.path, '1-a.wav'));
      await service.stop();

      expect(recorder.streamStarted, isTrue);
      expect(recorder.fileStarted, isFalse);
      expect(
        recorder.configs.single.encoder,
        AudioEncoder.pcm16bits,
        reason: 'only raw samples can be amplified',
      );
    });

    test('writes the file at the reserved staging path', () async {
      // The reservation machinery requires the capture to land exactly here;
      // a file written anywhere else is a lost recording.
      final String staging = p.join(dir.path, '1-a.wav');
      final FakeStreamRecorder recorder = FakeStreamRecorder(
        chunks: <List<int>>[pcm(<int>[100, 200, 300])],
      );
      final DefaultRecordingService service = serviceWith(recorder, 2.0);

      await service.start(stagingPath: staging);
      await service.stop();

      expect(File(staging).existsSync(), isTrue);
      expect(File(staging).lengthSync(), greaterThan(44));
    });

    test('amplifies the samples it writes', () async {
      final String staging = p.join(dir.path, '1-a.wav');
      final FakeStreamRecorder recorder = FakeStreamRecorder(
        chunks: <List<int>>[pcm(<int>[100, -200])],
      );
      final DefaultRecordingService service = serviceWith(recorder, 3.0);

      await service.start(stagingPath: staging);
      await service.stop();

      final Uint8List bytes = File(staging).readAsBytesSync();
      final ByteData payload = ByteData.sublistView(bytes, 44);
      expect(payload.getInt16(0, Endian.little), 300);
      expect(payload.getInt16(2, Endian.little), -600);
    });

    test('the header describes the real payload length', () async {
      // A stale length field is the classic streamed-WAV defect: the file
      // exists, looks fine, and plays as a fraction of a second.
      final String staging = p.join(dir.path, '1-a.wav');
      final FakeStreamRecorder recorder = FakeStreamRecorder(
        chunks: <List<int>>[
          pcm(<int>[1, 2, 3, 4]),
          pcm(<int>[5, 6, 7, 8]),
        ],
      );
      final DefaultRecordingService service = serviceWith(recorder, 2.0);

      await service.start(stagingPath: staging);
      await service.stop();

      final Uint8List bytes = File(staging).readAsBytesSync();
      final ByteData header = ByteData.sublistView(bytes, 0, 44);
      final int payload = bytes.length - 44;

      expect(payload, 16, reason: 'two 4-sample chunks');
      expect(
        header.getUint32(40, Endian.little),
        payload,
        reason: 'the data chunk size must match what was written',
      );
      expect(header.getUint32(4, Endian.little), 36 + payload);
    });

    test('joins chunks in order', () async {
      final String staging = p.join(dir.path, '1-a.wav');
      final FakeStreamRecorder recorder = FakeStreamRecorder(
        chunks: <List<int>>[
          pcm(<int>[10]),
          pcm(<int>[20]),
          pcm(<int>[30]),
        ],
      );
      final DefaultRecordingService service = serviceWith(recorder, 1.5);

      await service.start(stagingPath: staging);
      await service.stop();

      final ByteData payload =
          ByteData.sublistView(File(staging).readAsBytesSync(), 44);
      expect(payload.getInt16(0, Endian.little), 15);
      expect(payload.getInt16(2, Endian.little), 30);
      expect(payload.getInt16(4, Endian.little), 45);
    });

    test('stop returns the staging path', () async {
      final String staging = p.join(dir.path, '1-a.wav');
      final FakeStreamRecorder recorder = FakeStreamRecorder(
        chunks: <List<int>>[pcm(<int>[1])],
      );
      final DefaultRecordingService service = serviceWith(recorder, 2.0);

      await service.start(stagingPath: staging);
      final RecordingResult? result = await service.stop();

      expect(result?.path, staging);
    });
  });
}

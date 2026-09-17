// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:tangent/services/recording_service.dart';

/// Jeff records meetings through Bluetooth earbuds. Two behaviours matter and
/// they pull against each other:
///
///  1. When the chosen headset IS connected, its device must reach the
///     recorder's config, or the phone silently records on the built-in mic.
///  2. When the headset is NOT connected (switched off, out of range, battery
///     dead), recording must still START on the system default. A recording
///     that refuses to start because earbuds vanished is a worse bug than the
///     one this feature fixes.
///
/// A fake recorder stands in for hardware; these tests never touch a mic.
final class FakeAudioRecorder implements InputAwareAudioRecorder {
  FakeAudioRecorder({
    this.devices = const <InputDevice>[],
    this.listFailure,
    this.listDelay,
  });

  List<InputDevice> devices;
  Object? listFailure;
  Duration? listDelay;

  final List<RecordConfig> configs = <RecordConfig>[];
  int listCalls = 0;
  bool permission = true;
  String? startedPath;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<List<InputDevice>> listInputDevices() async {
    listCalls++;
    if (listDelay != null) await Future<void>.delayed(listDelay!);
    if (listFailure != null) throw listFailure!;
    return devices;
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    configs.add(config);
    startedPath = path;
    await File(path).writeAsBytes(<int>[1, 2, 3], flush: true);
  }

  @override
  Future<String?> stop() async => startedPath;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      const Stream<Amplitude>.empty();

  @override
  Future<void> dispose() async {}
}

const buds = InputDevice(
  id: 'bt-17',
  label: 'Galaxy Buds (Bluetooth telephony SCO, 00:11:22)',
);
const builtIn = InputDevice(id: '3', label: 'built-in microphone');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tangent-input-'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String staged(String name) => p.join(dir.path, name);

  group('input device selection', () {
    test('the chosen device is passed through to the recorder config',
        () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);
      await service.selectInputDevice(buds);

      await service.start(stagingPath: staged('a.opus'));

      expect(recorder.configs.single.device, buds);
    });

    test('no selection leaves the platform default in charge', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);

      await service.start(stagingPath: staged('b.opus'));

      expect(recorder.configs.single.device, isNull);
    });

    test('an unavailable remembered device falls back and still starts',
        () async {
      // The headset was chosen while connected, then switched off.
      final recorder = FakeAudioRecorder(devices: const [builtIn]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);
      await service.selectInputDevice(buds);
      service.debugForgetAvailability();

      final path = await service.start(stagingPath: staged('c.opus'));

      expect(path, staged('c.opus'));
      expect(recorder.configs.single.device, isNull,
          reason:
              'must fall back to the system default, not the dead headset',);
    });

    test('enumeration failure never blocks recording', () async {
      final recorder = FakeAudioRecorder(devices: const [buds])
        ..listFailure = StateError('BLUETOOTH_CONNECT denied');
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);
      await service.selectInputDevice(buds);
      service.debugForgetAvailability();

      final path = await service.start(stagingPath: staged('d.opus'));

      expect(path, staged('d.opus'));
      expect(recorder.configs.single.device, isNull);
    });

    test('start does not enumerate devices when nothing was chosen', () async {
      // The record tap is a hot path: a 5.8s folder enumeration was already
      // removed from it and must not come back as a device enumeration.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);

      await service.start(stagingPath: staged('e.opus'));

      expect(recorder.listCalls, 0);
    });

    test('a cached available device does not re-enumerate on start', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);
      await service.listInputDevices(); // Settings warmed the cache.
      await service.selectInputDevice(buds);
      final callsAfterSelect = recorder.listCalls;

      await service.start(stagingPath: staged('f.opus'));

      expect(recorder.listCalls, callsAfterSelect);
      expect(recorder.configs.single.device, buds);
    });

    test('the encoder and staging contract are unchanged', () async {
      final recorder = FakeAudioRecorder(devices: const [buds]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);
      await service.selectInputDevice(buds);

      final path = await service.start(stagingPath: staged('g.opus'));

      final config = recorder.configs.single;
      expect(path, staged('g.opus'));
      expect(config.encoder, AudioEncoder.opus);
      expect(config.sampleRate, 16000);
      expect(config.numChannels, 1);
      expect(config.bitRate, 32000);
    });

    test('listInputDevices surfaces what the platform reports', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);

      expect(await service.listInputDevices(), const [builtIn, buds]);
    });

    test('listInputDevices reports empty rather than throwing', () async {
      final recorder = FakeAudioRecorder()
        ..listFailure = StateError('BLUETOOTH_CONNECT denied');
      final service = DefaultRecordingService(outputDir: dir, recorder: recorder);

      expect(await service.listInputDevices(), isEmpty);
    });
  });
}

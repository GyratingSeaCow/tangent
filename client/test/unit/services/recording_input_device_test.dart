// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:tangent/services/communication_routing.dart';
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
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    configs.add(config);
    return const Stream<Uint8List>.empty();
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

/// Stands in for the native setCommunicationDevice() call.
final class FakeRouter implements CommunicationRouting {
  FakeRouter({this.gate, this.failure});
  final Completer<void>? gate;
  final Object? failure;
  final List<String> routed = <String>[];
  int cleared = 0;

  @override
  Future<CommunicationRoute> route(String? deviceId) async {
    if (deviceId == null) return CommunicationRoute.notApplicable;
    routed.add(deviceId);
    if (failure != null) throw failure!;
    if (gate != null) await gate!.future;
    return CommunicationRoute.applied;
  }

  @override
  Future<void> clear() async {
    cleared++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  group('communication routing', () {
    test('the chosen headset id is handed to the router', () async {
      // Without this the recorder honours the device in its config but Android
      // keeps capturing from the built-in mic, because the SCO link is never
      // brought up. Proven on hardware: dumpsys showed source client=MIC.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );
      await service.selectInputDevice(buds);

      await service.start(stagingPath: staged('r1.opus'));

      // Warmed at selection, so start() does not re-route an already-applied
      // device. What matters is that the headset id reached the router and was
      // not asked for twice.
      expect(router.routed, ['bt-17']);
    });

    test('routing is never awaited on the record path', () async {
      // A SCO link takes hundreds of ms to a second to come up. This app just
      // had a 5.8s stall removed from the record tap; capture must not wait.
      final gate = Completer<void>();
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter(gate: gate);
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        // Remembered from settings and never warmed, so start() is the first
        // thing to touch the router — the worst case for tap latency.
        initialDevice: buds,
        routing: router,
      );

      await service.start(stagingPath: staged('r2.opus')).timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('start() waited for the SCO route'),
          );

      expect(
        recorder.startedPath,
        isNotNull,
        reason: 'capture must already be running',
      );
      expect(
        gate.isCompleted,
        isFalse,
        reason: 'the route was still pending when recording began',
      );
      gate.complete();
    });

    test('a router failure does not stop the recording', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter(failure: StateError('synthetic route fault'));
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );
      await service.selectInputDevice(buds);

      await service.start(stagingPath: staged('r3.opus'));

      expect(recorder.startedPath, isNotNull);
    });

    test('no selection means no routing round trip', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );

      await service.start(stagingPath: staged('r4.opus'));

      expect(router.routed, isEmpty);
    });

    test('stopping releases the route', () async {
      // Leaving it applied pins the phone in call-audio mode.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );
      await service.selectInputDevice(buds);
      await service.start(stagingPath: staged('r5.opus'));

      await service.stop();

      expect(router.cleared, 1);
    });
  });
  group('route warming', () {
    // Device evidence (Fold + AirPods Pro): firing the route at record time is
    // too late. The applied device showed role:output type:bt_sco, but capture
    // still read `source client=MIC` because the recorder bound its input
    // stream before the asynchronous route landed. Warming at SELECTION time
    // gets SCO up before the tap, without putting any delay on the tap itself.
    test('choosing a headset warms the route immediately', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );

      await service.selectInputDevice(buds);

      expect(router.routed, ['bt-17']);
    });

    test('choosing the system default releases the route', () async {
      // Otherwise the phone stays pinned in call-audio mode after the user
      // deliberately went back to the built-in mic.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );
      await service.selectInputDevice(buds);

      await service.selectInputDevice(null);

      expect(router.cleared, 1);
    });

    test('warming failure never breaks selection', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter(failure: StateError('synthetic warm fault'));
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );

      await service.selectInputDevice(buds);

      expect(service.selectedDevice, buds);
    });

    test('warmRoute re-applies the remembered headset', () async {
      // Called when the app returns to the foreground so the route is live
      // again by the time the user reaches for record.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        initialDevice: buds,
        routing: router,
      );

      await service.warmRoute();

      expect(router.routed, ['bt-17']);
    });

    test('warmRoute does nothing without a selection', () async {
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );

      await service.warmRoute();

      expect(router.routed, isEmpty);
    });

    test('releaseRouteIfIdle frees the route when not recording', () async {
      // Leaving call-audio mode applied while the app sits in the background
      // would degrade the user's music playback.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );
      await service.selectInputDevice(buds);

      await service.releaseRouteIfIdle();

      expect(router.cleared, 1);
    });

    test('releaseRouteIfIdle NEVER clears during an active recording',
        () async {
      // Backgrounding the app mid-recording must not yank the microphone out
      // from under a capture that is still running.
      final recorder = FakeAudioRecorder(devices: const [builtIn, buds]);
      final router = FakeRouter();
      final service = DefaultRecordingService(
        outputDir: dir,
        recorder: recorder,
        routing: router,
      );
      await service.selectInputDevice(buds);
      await service.start(stagingPath: staged('w1.opus'));

      await service.releaseRouteIfIdle();

      expect(
        router.cleared,
        0,
        reason: 'an in-flight recording still needs the headset route',
      );
    });
  });
}

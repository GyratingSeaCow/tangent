// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:tangent/services/communication_routing.dart';
import 'package:tangent/services/recording_service.dart';

/// Automatic Bluetooth capture — "It needs to default to the system defaults
/// like it does when you enter into calls" (Jeff, 2026-09-23, after the
/// Phase-A isolation test proved BLUETOOTH_CONNECT was the only blocker).
///
/// The contract:
///  * auto ON + no manual choice  -> the service asks the platform to route
///    like a phone call (routeAuto), gated on the runtime permission
///  * permission denied           -> no routing, recording proceeds built-in
///  * a manual selection          -> wins over auto; routeAuto never fires
///  * auto OFF                    -> the platform is never asked
///  * warmRoute (app foreground)  -> may pre-route, but must never prompt
final class FakeAudioRecorder implements InputAwareAudioRecorder {
  FakeAudioRecorder({this.devices = const <InputDevice>[]});

  List<InputDevice> devices;
  final List<RecordConfig> configs = <RecordConfig>[];
  String? startedPath;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<List<InputDevice>> listInputDevices() async => devices;

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

final class AutoFakeRouter implements CommunicationRouting {
  final List<String> routed = <String>[];
  int autoRouted = 0;
  int cleared = 0;

  @override
  Future<CommunicationRoute> route(String? deviceId) async {
    if (deviceId == null) return CommunicationRoute.notApplicable;
    routed.add(deviceId);
    return CommunicationRoute.applied;
  }

  @override
  Future<CommunicationRoute> routeAuto() async {
    autoRouted++;
    return CommunicationRoute.applied;
  }

  @override
  Future<void> clear() async {
    cleared++;
  }
}

/// Records how the permission gate was consulted.
final class PermissionLog {
  PermissionLog(this.granted);
  bool granted;
  final List<bool> interactives = <bool>[];

  Future<bool> call({required bool interactive}) async {
    interactives.add(interactive);
    return granted;
  }
}

const buds = InputDevice(
  id: 'bt-17',
  label: 'Galaxy Buds (Bluetooth telephony SCO, 00:11:22)',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tangent-autobt-'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String staged(String name) => p.join(dir.path, name);

  ({
    DefaultRecordingService service,
    AutoFakeRouter router,
    PermissionLog permission,
  }) build({bool auto = true, bool granted = true}) {
    final router = AutoFakeRouter();
    final permission = PermissionLog(granted);
    final service = DefaultRecordingService(
      outputDir: dir,
      recorder: FakeAudioRecorder(),
      routing: router,
      autoRouteBluetooth: () => auto,
      bluetoothPermission: permission.call,
    );
    return (service: service, router: router, permission: permission);
  }

  test('auto mode routes like a call when recording starts', () async {
    final f = build();
    await f.service.start(stagingPath: staged('a.opus'));
    // The route fires unawaited (T6: nothing may stall the record tap).
    await pumpEventQueue();

    expect(f.router.autoRouted, 1);
    expect(f.router.routed, isEmpty, reason: 'no manual id to route');
    expect(
      f.permission.interactives,
      [true],
      reason: 'a record tap may show the permission dialog',
    );
  });

  test('permission denied: recording proceeds, nothing is routed', () async {
    final f = build(granted: false);
    await f.service.start(stagingPath: staged('a.opus'));
    await pumpEventQueue();

    expect(f.router.autoRouted, 0);
  });

  test('a manual selection wins over auto', () async {
    final f = build();
    final recorder = FakeAudioRecorder(devices: const [buds]);
    final service = DefaultRecordingService(
      outputDir: dir,
      recorder: recorder,
      routing: f.router,
      autoRouteBluetooth: () => true,
      bluetoothPermission: f.permission.call,
    );
    await service.selectInputDevice(buds);
    await service.start(stagingPath: staged('a.opus'));
    await pumpEventQueue();

    expect(f.router.routed, ['bt-17']);
    expect(f.router.autoRouted, 0);
  });

  test('auto off: the platform is never asked', () async {
    final f = build(auto: false);
    await f.service.start(stagingPath: staged('a.opus'));
    await pumpEventQueue();

    expect(f.router.autoRouted, 0);
    expect(f.permission.interactives, isEmpty);
  });

  test('warmRoute pre-routes silently — never a prompt', () async {
    final f = build();
    await f.service.warmRoute();

    expect(f.router.autoRouted, 1);
    expect(
      f.permission.interactives,
      [false],
      reason: 'app foreground must not pop a permission dialog',
    );
  });

  test('warmRoute without permission stays quiet and routes nothing', () async {
    final f = build(granted: false);
    await f.service.warmRoute();

    expect(f.router.autoRouted, 0);
  });

  test('releasing when idle clears an auto route too', () async {
    final f = build();
    await f.service.start(stagingPath: staged('a.opus'));
    await pumpEventQueue();
    await f.service.stop();
    await f.service.releaseRouteIfIdle();

    expect(f.router.cleared, greaterThanOrEqualTo(1));
  });
}

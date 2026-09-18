// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/communication_routing.dart';

/// Routing capture to a Bluetooth headset mic.
///
/// The `record` plugin drives the deprecated startBluetoothSco() pair, which
/// does not bring SCO up on the target hardware — verified on a Galaxy Z Fold
/// with AirPods Pro, where `dumpsys audio` reported `source client=MIC` and
/// `mScoAudioState: SCO_STATE_INACTIVE` while the headset was selected. The
/// native side uses setCommunicationDevice() instead; this is its Dart face.
///
/// The governing rule in every test below: routing is best-effort. A headset
/// that is off, refused, or unsupported must never stop a recording.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fixture/communication-routing');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('routing a chosen headset reports that it was applied', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'state': 'applied', 'label': 'AirPods Pro'};
    });

    final routing = CommunicationRouting(channel: channel);
    final result = await routing.route('1535');

    expect(result, CommunicationRoute.applied);
    expect(calls.single.method, 'routeCommunicationDevice');
    expect(calls.single.arguments, {'deviceId': 1535});
  });

  test('a missing headset reports absent instead of throwing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {'state': 'absent', 'label': null};
    });

    final routing = CommunicationRouting(channel: channel);
    expect(await routing.route('1535'), CommunicationRoute.absent);
  });

  test('a native failure never propagates to the record path', () async {
    // If this threw, tapping record with a dead headset would fail outright.
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom', message: 'synthetic native fault');
    });

    final routing = CommunicationRouting(channel: channel);
    expect(await routing.route('1535'), CommunicationRoute.unavailable);
  });

  test('a null selection does not call the platform at all', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    final routing = CommunicationRouting(channel: channel);
    expect(await routing.route(null), CommunicationRoute.notApplicable);
    expect(
      calls,
      isEmpty,
      reason: 'the default microphone needs no routing round trip',
    );
  });

  test('clearing releases the route and survives a native failure', () async {
    var cleared = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clearCommunicationDevice') {
        cleared++;
        throw PlatformException(code: 'boom');
      }
      return null;
    });

    final routing = CommunicationRouting(channel: channel);
    await routing.clear(); // must not throw

    expect(cleared, 1);
  });

  test('an unrecognised native state degrades to unavailable', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {'state': 'something-new-from-a-future-platform'};
    });

    final routing = CommunicationRouting(channel: channel);
    expect(await routing.route('1535'), CommunicationRoute.unavailable);
  });
}

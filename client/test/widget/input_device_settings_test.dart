// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/settings/input_device_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';

/// The microphone picker lives in Settings, never on the record path, and
/// must make the quality trade-off explicit: Bluetooth headset mics run over
/// SCO/HFP at 8-16 kHz mono and transcribe measurably worse than the built-in
/// mic. It is opt-in and never auto-switches to a connected headset.
class FakeInputService with NoInputDeviceSelection implements RecordingService {
  FakeInputService(this._devices);
  final List<InputDevice> _devices;
  InputDevice? selected;
  int listCalls = 0;

  @override
  Future<List<InputDevice>> listInputDevices() async {
    listCalls++;
    return _devices;
  }

  @override
  Future<void> selectInputDevice(InputDevice? device) async {
    selected = device;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const buds = InputDevice(
  id: 'bt-17',
  label: 'Galaxy Buds (Bluetooth telephony SCO, 00:11:22)',
);
const builtIn = InputDevice(id: '3', label: 'Built-in (built-in microphone)');

Future<void> pump(
  WidgetTester tester, {
  required FakeInputService service,
  required SettingsStore settings,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recordingServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(settings),
      ],
      child: const MaterialApp(
        home: Scaffold(body: InputDeviceSection()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('defaults to the system default microphone', (tester) async {
    final service = FakeInputService(const [builtIn, buds]);
    await pump(tester, service: service, settings: SettingsStore());

    expect(find.text('Microphone'), findsOneWidget);
    expect(find.textContaining('System default'), findsOneWidget);
  });

  testWidgets('explains why Bluetooth headsets are not listed', (tester) async {
    // The absence needs a reason, or it reads as a missing feature. Device
    // evidence: Android exposes no input-role device for the headset, so
    // offering it would silently record from the phone's own mic.
    final service = FakeInputService(const [builtIn, buds]);
    await pump(tester, service: service, settings: SettingsStore());

    expect(
      find.textContaining(
        RegExp('bluetooth headsets are not listed', caseSensitive: false),
      ),
      findsOneWidget,
      reason: 'the omission must be explained, not silent',
    );
  });

  testWidgets('choosing a built-in mic persists it and tells the recorder',
      (tester) async {
    // Bluetooth headsets are deliberately not offered (see the hiding test
    // below), so selection is exercised with a device that can actually be
    // recorded from.
    final service = FakeInputService(const [builtIn, buds]);
    final settings = SettingsStore();
    await pump(tester, service: service, settings: settings);

    await tester.tap(find.text('Microphone'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Built-in').last);
    await tester.pumpAndSettle();

    expect(settings.preferredInputDeviceId, '3');
    expect(service.selected, builtIn);
  });

  testWidgets('a remembered mic that is gone shows as unavailable',
      (tester) async {
    // Chosen while present, then that microphone disappeared.
    final service = FakeInputService(const [builtIn]);
    final settings = SettingsStore(
      preferredInputDeviceId: 'usb-9',
      preferredInputDeviceLabel: 'USB microphone',
    );
    await pump(tester, service: service, settings: settings);

    // Scoped to the Microphone row: the explanatory caveat paragraph also
    // contains the word "unavailable".
    final subtitle = find.textContaining('USB microphone');
    expect(subtitle, findsOneWidget);
    expect(
      tester.widget<Text>(subtitle).data,
      contains('unavailable'),
      reason: 'a vanished mic must say so rather than imply it is in use',
    );
  });

  testWidgets('can return to the system default', (tester) async {
    final service = FakeInputService(const [builtIn, buds]);
    final settings = SettingsStore(
      preferredInputDeviceId: 'bt-17',
      preferredInputDeviceLabel: 'Galaxy Buds',
    );
    await pump(tester, service: service, settings: settings);

    await tester.tap(find.text('Microphone'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('System default').last);
    await tester.pumpAndSettle();

    expect(settings.preferredInputDeviceId, isNull);
    expect(service.selected, isNull);
  });
  testWidgets('Bluetooth headsets are not offered as recording inputs',
      (tester) async {
    // Device verdict (Fold + AirPods Pro, 2026-09-17): the routing plumbing
    // works — setCommunicationDevice() applies, the headset reaches
    // mScoAudioState: SCO_STATE_ACTIVE_INTERNAL, and the route is released on
    // stop. But capture STILL reads `source client=MIC` and Android reports no
    // input-role devices, so the recorder never receives the headset mic.
    //
    // Offering the choice would be a lie: the row would read "AirPods Pro"
    // while the phone quietly recorded from its own microphone. Hide SCO
    // devices until a custom recorder can actually capture from them.
    final service = FakeInputService(const [builtIn, buds]);
    await pump(tester, service: service, settings: SettingsStore());

    await tester.tap(find.text('Microphone'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Galaxy Buds'),
      findsNothing,
      reason: 'a Bluetooth headset mic cannot actually be recorded from yet',
    );
    expect(find.textContaining('Built-in'), findsOneWidget);
    expect(find.text('System default'), findsOneWidget);
  });

  testWidgets('a remembered headset no longer claims to be in use',
      (tester) async {
    // Someone who chose earbuds on an earlier build must not keep seeing them
    // presented as the active microphone.
    final service = FakeInputService(const [builtIn, buds]);
    final settings = SettingsStore(
      preferredInputDeviceId: 'bt-17',
      preferredInputDeviceLabel: 'Galaxy Buds',
    );
    await pump(tester, service: service, settings: settings);

    expect(find.textContaining('Galaxy Buds'), findsNothing);
  });
}

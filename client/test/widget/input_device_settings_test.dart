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

  testWidgets('warns that a headset mic degrades transcription',
      (tester) async {
    final service = FakeInputService(const [builtIn, buds]);
    await pump(tester, service: service, settings: SettingsStore());

    expect(
      find.textContaining(
        RegExp('lower quality|worse|degrade', caseSensitive: false),
      ),
      findsWidgets,
      reason: 'the SCO quality trade-off must be stated, not hidden',
    );
  });

  testWidgets('choosing a headset persists it and tells the recorder',
      (tester) async {
    final service = FakeInputService(const [builtIn, buds]);
    final settings = SettingsStore();
    await pump(tester, service: service, settings: settings);

    await tester.tap(find.text('Microphone'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Galaxy Buds').last);
    await tester.pumpAndSettle();

    expect(settings.preferredInputDeviceId, 'bt-17');
    expect(service.selected, buds);
  });

  testWidgets('a remembered headset that is gone shows as unavailable',
      (tester) async {
    // Chosen while connected, then the earbuds were switched off.
    final service = FakeInputService(const [builtIn]);
    final settings = SettingsStore(
      preferredInputDeviceId: 'bt-17',
      preferredInputDeviceLabel: 'Galaxy Buds',
    );
    await pump(tester, service: service, settings: settings);

    expect(find.textContaining('Galaxy Buds'), findsOneWidget);
    expect(
      find.textContaining(
        RegExp('unavailable|not connected', caseSensitive: false),
      ),
      findsOneWidget,
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
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import '../support/widget_recording_coordinator.dart';

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Reproduces the on-device defect where the recording timer stayed at 00:00
/// throughout an active capture: elapsed display must advance while recording.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recording timer advances past 00:00 during capture',
      (tester) async {
    final service = StubRecordingService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingServiceProvider.overrideWithValue(service),
          recordingCoordinatorProvider
              .overrideWith((ref) => WidgetRecordingCoordinator(service)),
          storageBootstrapProvider.overrideWith((ref) async {}),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    expect(find.text('00:00'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsOneWidget);
    // Let real wall-clock time pass (elapsed uses DateTime.now()), then fire
    // the controller's periodic UI tick inside the fake-async clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('00:00'),
      findsNothing,
      reason: 'elapsed timer must advance while recording',
    );
    expect(find.text('00:01'), findsOneWidget);
    // A second tick keeps advancing rather than freezing after one repaint.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:02'), findsOneWidget);
    // Stopping resets the idle display to 00:00.
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    expect(find.text('00:00'), findsOneWidget);
  });
}

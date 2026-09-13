// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/services/recording_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller starts in idle state', () {
    final container = ProviderContainer(overrides: [
      recordingServiceProvider.overrideWithValue(StubRecordingService()),
    ]);
    addTearDown(container.dispose);
    expect(container.read(recordingControllerProvider), RecordingState.idle);
    expect(container.read(recordingControllerProvider.notifier).isRecording,
        isFalse);
  });

  test('elapsedSeconds is 0 when idle', () {
    final container = ProviderContainer(overrides: [
      recordingServiceProvider.overrideWithValue(StubRecordingService()),
    ]);
    addTearDown(container.dispose);
    expect(
      container.read(recordingControllerProvider.notifier).elapsedSeconds,
      0,
    );
  });
}
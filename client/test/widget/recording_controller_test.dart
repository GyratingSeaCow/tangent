// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/recording/recording_controller.dart';

void main() {
  test('controller starts in idle state', () async {
    final tmp = await Directory.systemTemp.createTemp('tangent_ctrl_');
    final container = ProviderContainer(overrides: [
      recordingControllerProvider.overrideWith((ref) {
        final c = RecordingController.test(outputDir: tmp);
        ref.onDispose(() => tmp.delete(recursive: true));
        return c;
      }),
    ]);
    addTearDown(container.dispose);
    expect(container.read(recordingControllerProvider), RecordingState.idle);
    expect(container.read(recordingControllerProvider.notifier).isRecording,
        isFalse);
  });

  test('elapsedSeconds is 0 when idle', () async {
    final tmp = await Directory.systemTemp.createTemp('tangent_ctrl2_');
    final container = ProviderContainer(overrides: [
      recordingControllerProvider.overrideWith((ref) {
        final c = RecordingController.test(outputDir: tmp);
        ref.onDispose(() => tmp.delete(recursive: true));
        return c;
      }),
    ]);
    addTearDown(container.dispose);
    expect(container.read(recordingControllerProvider.notifier).elapsedSeconds, 0);
  });
}
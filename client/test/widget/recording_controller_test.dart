// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/recording/waveform_state.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/services/recording_coordinator.dart';
import '../support/file_recorder.dart';
import '../support/scripted_storage_backend.dart';
import '../support/storage_fixture.dart';

import '../support/widget_recording_coordinator.dart';

class FakeScreenAwake implements ScreenAwake {
  final events = <bool>[];
  @override
  Future<void> setEnabled(bool enabled) async => events.add(enabled);
}

class FailingStopRecordingService extends StubRecordingService {
  @override
  Future<RecordingResult?> stop() async => throw StateError('stop failed');
}

class FailingStartRecordingService extends StubRecordingService {
  @override
  Future<String> start({required String stagingPath}) async =>
      throw StateError('start failed');
}

ProviderContainer containerFor(
  RecordingService service, {
  ScreenAwake? awake,
  SettingsStore? settings,
}) {
  return ProviderContainer(
    overrides: [
      recordingServiceProvider.overrideWithValue(service),
      recordingCoordinatorProvider
          .overrideWithValue(WidgetRecordingCoordinator(service)),
      storageBootstrapProvider.overrideWith((ref) async {}),
      screenAwakeProvider.overrideWithValue(awake ?? FakeScreenAwake()),
      settingsStoreProvider.overrideWithValue(settings ?? SettingsStore()),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'real recording pipeline stays saving until settlement and pins start mode',
      () async {
    final h = CatalogHarness();
    final recorder = FileRecorder();
    final observed = Completer<void>();
    final finished = Completer<void>();
    final awake = FakeScreenAwake();
    final coordinator = DefaultRecordingCoordinator(
      db: h.f.db,
      catalog: h.catalog,
      backend: h.backend,
      mutations: h.mutations,
      recorder: recorder,
      now: () => DateTime.utc(2030),
    );
    final container = ProviderContainer(
      overrides: [
        recordingServiceProvider.overrideWithValue(recorder),
        recordingCoordinatorProvider.overrideWithValue(coordinator),
        storageBootstrapProvider.overrideWith((ref) => h.bootstrap()),
        screenAwakeProvider.overrideWithValue(awake),
        settingsStoreProvider.overrideWithValue(SettingsStore()),
      ],
    );
    Future<DumpRow?>? pending;
    addTearDown(() async {
      if (!finished.isCompleted) finished.complete();
      await pending;
      container.dispose();
      await recorder.dispose();
      await h.close();
    });
    h.backend.publication = (r, metadata) {
      final result = settled(h.f.backend.publishPreparedCapture(r, metadata))
          .then((value) {
        observed.complete();
        return value;
      });
      return GatedIo('fixture-controller-publication', result, finished.future);
    };
    final controller = container.read(recordingControllerProvider.notifier);
    await controller.start(mode: 'meeting');
    pending = controller.stop();
    await observed.future;
    expect(container.read(recordingControllerProvider), RecordingState.saving);
    await controller.start(mode: 'brain_dump');
    expect(await h.f.db.select(h.f.db.dumps).get(), isEmpty);
    expect(h.mutations.hasActiveCapture, isTrue);
    finished.complete();
    final row = (await pending)!;
    expect(row.mode, 'meeting');
    expect(row.syncStatus, 'local_only');
    expect(container.read(recordingControllerProvider), RecordingState.idle);
    expect(awake.events, [true, false]);
  });

  test('controller starts in idle state', () {
    final container = containerFor(StubRecordingService());
    addTearDown(container.dispose);
    expect(container.read(recordingControllerProvider), RecordingState.idle);
    expect(
      container.read(recordingControllerProvider.notifier).isRecording,
      isFalse,
    );
  });

  test('elapsedSeconds is 0 when idle', () {
    final container = containerFor(StubRecordingService());
    addTearDown(container.dispose);
    expect(
      container.read(recordingControllerProvider.notifier).elapsedSeconds,
      0,
    );
  });

  test('screen awake is enabled only while recording and released on stop',
      () async {
    final awake = FakeScreenAwake();
    final container = containerFor(StubRecordingService(), awake: awake);
    addTearDown(container.dispose);

    await container
        .read(recordingControllerProvider.notifier)
        .start(mode: 'brain_dump');
    await container.read(recordingControllerProvider.notifier).stop();
    expect(awake.events, [true, false]);
  });

  test('disabled screen-awake preference never enables the flag', () async {
    final awake = FakeScreenAwake();
    final container = containerFor(
      StubRecordingService(),
      awake: awake,
      settings: SettingsStore(keepScreenAwakeWhileRecording: false),
    );
    addTearDown(container.dispose);

    await container
        .read(recordingControllerProvider.notifier)
        .start(mode: 'brain_dump');
    await container.read(recordingControllerProvider.notifier).stop();
    expect(awake.events, [false]);
  });

  test('stop failure releases screen awake and returns controller to idle',
      () async {
    final awake = FakeScreenAwake();
    final container = containerFor(FailingStopRecordingService(), awake: awake);
    addTearDown(container.dispose);

    await container
        .read(recordingControllerProvider.notifier)
        .start(mode: 'brain_dump');
    await expectLater(
      container.read(recordingControllerProvider.notifier).stop(),
      throwsStateError,
    );
    expect(awake.events, [true, false]);
    expect(container.read(recordingControllerProvider), RecordingState.idle);
  });

  test('amplitude updates waveform and stop clears it', () async {
    final service = StubRecordingService();
    final container = containerFor(service);
    addTearDown(container.dispose);

    await container
        .read(recordingControllerProvider.notifier)
        .start(mode: 'brain_dump');
    service.emitAmplitude(-12);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(waveformProvider).last, greaterThan(0));
    expect(service.events, contains('amplitude:60'));
    await container.read(recordingControllerProvider.notifier).stop();
    expect(container.read(waveformProvider), everyElement(0));
  });

  test('start failure never subscribes to amplitude', () async {
    final service = FailingStartRecordingService();
    final container = containerFor(service);
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(recordingControllerProvider.notifier)
          .start(mode: 'brain_dump'),
      throwsStateError,
    );
    expect(
      service.events.where((event) => event.startsWith('amplitude:')),
      isEmpty,
    );
    expect(container.read(waveformProvider), everyElement(0));
  });

  test('amplitude error clears waveform but recording continues', () async {
    final service = StubRecordingService();
    final container = containerFor(service);
    addTearDown(container.dispose);

    await container
        .read(recordingControllerProvider.notifier)
        .start(mode: 'brain_dump');
    service.emitAmplitude(-10);
    await Future<void>.delayed(Duration.zero);
    service.emitAmplitudeError(StateError('amplitude failed'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(recordingControllerProvider),
      RecordingState.recording,
    );
    expect(container.read(waveformProvider), everyElement(0));
    await container.read(recordingControllerProvider.notifier).stop();
  });
}

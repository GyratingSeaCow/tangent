// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';

/// Recording is the app's primary function, so tapping record must not wait for
/// the catalog to finish scanning the user's folder.
///
/// Measured on device before this split: cold launch was 851 ms, but a record
/// tap 1.7 s later left the timer at 00:00 for more than 21 s, because
/// `start()` awaited the whole storage bootstrap — fence restoration AND a full
/// SAF enumeration adopting 39 recordings. The tap looked swallowed.
class _StubRecordingService implements RecordingService {
  @override
  Stream<double> amplitudeStream(Duration interval) =>
      const Stream<double>.empty();
  @override
  Future<void> dispose() async {}
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _StubCoordinator implements RecordingCoordinator {
  int starts = 0;
  @override
  Future<Outcome<CaptureReservation>> start({required String mode}) async {
    starts++;
    return Ok((
      id: 'stub-reservation',
      key: (dumpId: 'stub-capture', incarnation: '1'),
      location: (
        id: 'stub-location',
        label: 'Stub',
        directory: (
          kind: 'saf',
          path: '',
          treeUri: 'content://stub/tree/root',
          authority: 'stub',
          documentId: 'root'
        )
      ),
      mode: mode,
      phase: CapturePhase.reserved,
      stagingPath: '/stub/staging/stub-capture',
      startedAt: DateTime.utc(2026),
    ),);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start() proceeds while the catalog sweep is still running', () async {
    // catalogSync is gated open by this completer, so it is provably unfinished
    // while start() runs. If start() ever awaits the catalog again, this test
    // times out instead of passing — which is exactly the regression to catch.
    final catalogGate = Completer<void>();
    addTearDown(() {
      if (!catalogGate.isCompleted) catalogGate.complete();
    },);
    final coordinator = _StubCoordinator();

    final container = ProviderContainer(
      overrides: [
        captureReadyProvider.overrideWith((ref) async {}),
        catalogSyncProvider.overrideWith((ref) => catalogGate.future),
        recordingServiceProvider.overrideWithValue(_StubRecordingService()),
        recordingCoordinatorProvider.overrideWithValue(coordinator),
        screenAwakeProvider.overrideWithValue(_StubScreenAwake()),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(recordingControllerProvider.notifier);
    await controller.start(mode: 'brain_dump').timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'start() blocked on the catalog sweep: the record button is '
            'gated behind the folder scan again.',
          ),
        );

    expect(controller.isRecording, isTrue);
    expect(coordinator.starts, 1);
    expect(
      catalogGate.isCompleted,
      isFalse,
      reason: 'The catalog sweep must still be pending — otherwise this test '
          'proves nothing about ordering.',
    );
  });

  test('a capture-readiness failure still stops the recording', () async {
    // The split must not swallow real capture faults: fence restoration and
    // owned-capture recovery failing means a capture is unsafe to start.
    final container = ProviderContainer(
      overrides: [
        captureReadyProvider.overrideWith(
          (ref) async => throw const StorageFault(
            (code: ProblemCode.io, message: 'fixture capture-ready failure'),
          ),
        ),
        catalogSyncProvider.overrideWith((ref) async {}),
        recordingServiceProvider.overrideWithValue(_StubRecordingService()),
        recordingCoordinatorProvider.overrideWithValue(_StubCoordinator()),
        screenAwakeProvider.overrideWithValue(_StubScreenAwake()),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(recordingControllerProvider.notifier);
    await expectLater(
      controller.start(mode: 'brain_dump'),
      throwsA(isA<StorageFault>()),
    );
    expect(controller.isRecording, isFalse);
  });

  test('a catalog sweep failure does not prevent recording', () async {
    // An unreadable folder or a bad notebook file is not a reason to refuse to
    // record: the catalog is a convenience, capture is the product.
    final container = ProviderContainer(
      overrides: [
        captureReadyProvider.overrideWith((ref) async {}),
        catalogSyncProvider.overrideWith(
          (ref) async => throw const StorageFault(
            (code: ProblemCode.io, message: 'fixture catalog failure'),
          ),
        ),
        recordingServiceProvider.overrideWithValue(_StubRecordingService()),
        recordingCoordinatorProvider.overrideWithValue(_StubCoordinator()),
        screenAwakeProvider.overrideWithValue(_StubScreenAwake()),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(recordingControllerProvider.notifier);
    await controller.start(mode: 'brain_dump');
    expect(controller.isRecording, isTrue);
  });
}

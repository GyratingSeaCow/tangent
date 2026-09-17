// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/bound_row_fixture.dart';
import '../../../support/bound_service_fixture.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import '../../../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/services/transcription_client.dart';

class _ProviderRecoveryClient extends TranscriptionClient {
  _ProviderRecoveryClient({
    required this.snapshot,
    required this.events,
  }) : super(baseUrl: 'http://test');

  final TranscriptionJobSnapshot snapshot;
  final Stream<JobEvent> events;
  final Completer<void> getJobStarted = Completer<void>();
  final Completer<void> streamJobStarted = Completer<void>();
  int getJobCalls = 0;
  int streamJobCalls = 0;

  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async {
    getJobCalls += 1;
    if (!getJobStarted.isCompleted) getJobStarted.complete();
    return snapshot;
  }

  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) {
    streamJobCalls += 1;
    if (!streamJobStarted.isCompleted) streamJobStarted.complete();
    return events;
  }
}

void main() {
  test('client replacement recreates the service and reconciles automatically',
      () async {
    final temp =
        Directory.systemTemp.createTempSync('tangent-provider-recovery-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final firstStreamCanceled = Completer<void>();
    final firstEvents = StreamController<JobEvent>.broadcast(
      onCancel: firstStreamCanceled.complete,
    );
    final firstClient = _ProviderRecoveryClient(
      snapshot: const TranscriptionJobSnapshot(
        id: 'job-provider',
        requestId: 'request-provider',
        dumpId: 'provider-row',
        status: 'running',
        model: 'large-v3',
      ),
      events: firstEvents.stream,
    );
    final secondClient = _ProviderRecoveryClient(
      snapshot: const TranscriptionJobSnapshot(
        id: 'job-provider',
        requestId: 'request-provider',
        dumpId: 'provider-row',
        status: 'completed',
        model: 'large-v3',
        transcript: 'reconciled by replacement',
      ),
      events: const Stream<JobEvent>.empty(),
    );
    await seedFileFixtureRow(
      db,
      DumpRow(
        id: 'provider-row',
        createdAt: DateTime.utc(2026, 9, 15),
        updatedAt: DateTime.utc(2026, 9, 15),
        mode: 'brain_dump',
        durationSeconds: 5,
        title: 'Provider recovery',
        audioPath: storage.pathFor('provider-row').path,
        audioSizeBytes: 3,
        syncStatus: 'pending',
        syncAttempts: 0,
        transcriptionStatus: 'running',
        transcriptionRequestId: 'request-provider',
        transcriptionJobId: 'job-provider',
        transcriptionAttempt: 1,
      ),
    );
    storage.pathFor('provider-row').writeAsBytesSync([1, 2, 3]);
    final bound = await createBoundServiceFixture(db);
    final container = ProviderContainer(
      overrides: [
        localDbProvider.overrideWithValue(db),
        audioStorageProvider.overrideWithValue(storage),
        recordingMutationsProvider.overrideWithValue(bound.mutations),
        recordingAccessProvider.overrideWithValue(bound.access),
        transcriptionClientProvider.overrideWith((ref) => firstClient),
      ],
    );
    final subscription = container.listen(
      serverTranscriptionServiceProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await firstEvents.close();
      await bound.mutations.drain();
      await db.close();
      temp.deleteSync(recursive: true);
    });

    final firstService = container.read(serverTranscriptionServiceProvider);
    await firstClient.getJobStarted.future
        .timeout(const Duration(milliseconds: 200));
    await firstClient.streamJobStarted.future
        .timeout(const Duration(milliseconds: 200));
    expect(firstClient.getJobCalls, 1);
    expect(firstClient.streamJobCalls, 1);

    container.read(transcriptionClientProvider.notifier).state = secondClient;
    final secondService = container.read(serverTranscriptionServiceProvider);

    await firstStreamCanceled.future.timeout(const Duration(milliseconds: 200));
    await secondClient.getJobStarted.future
        .timeout(const Duration(milliseconds: 200));
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    late DumpRow recovered;
    while (true) {
      recovered = (await db.getDump('provider-row'))!;
      if (recovered.transcriptionStatus == 'completed' &&
          recovered.transcriptionError == null) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('replacement service did not finish durable sidecar recovery');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(secondService, isNot(same(firstService)));
    expect(() => firstService.transcribeDump('provider-row'), throwsStateError);
    expect(secondClient.getJobCalls, 1);
    expect(secondClient.streamJobCalls, 0);
    expect(recovered.transcript, 'reconciled by replacement');
    expect(recovered.transcriptionRequestId, 'request-provider');
    expect(recovered.transcriptionJobId, 'job-provider');
    expect(recovered.transcriptionAttempt, 1);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';
import 'package:tangent/services/server_transcription.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

void main() {
  testWidgets(
      'Dumps list identifies the recording being transcribed on the server',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-list-progress-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final service = _QueuedService(db: db, audioStorage: storage);
    final fake = _FakeClient();
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });

    await db.upsertDump(_row('active', 'Currently processing'));
    await db.upsertDump(_row('queued', 'Waiting recording'));
    await db.upsertDump(_row('other', 'Another recording'));
    await db.upsertDump(_row('meeting', 'Meeting recording', mode: 'meeting'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          transcriptionClientProvider.overrideWith((ref) => fake),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
        ],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('transcription-indicator-active')),
      findsOneWidget,
    );
    expect(find.text('Uploading to your server…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('transcription-queued-queued')),
      findsOneWidget,
    );
    expect(find.textContaining('Queued'), findsWidgets);
    expect(
      find.byKey(const ValueKey('transcription-indicator-other')),
      findsNothing,
    );
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Brain Dump'), findsOneWidget);
    expect(find.text('Meeting'), findsOneWidget);
    expect(find.text('Awaiting'), findsOneWidget);

    await tester.tap(find.text('Meeting'));
    await tester.pumpAndSettle();
    expect(find.text('Meeting recording'), findsOneWidget);
    expect(find.text('Currently processing'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

DumpRow _row(String id, String title, {String mode = 'brain_dump'}) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
      mode: mode,
      durationSeconds: 9,
      title: title,
      audioPath: 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );

class _FakeClient implements TranscriptionClient {
  @override
  String get baseUrl => 'http://test';
  @override
  Future<ServerInfo> getServerInfo() async => throw UnimplementedError();
  @override
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async =>
      id;
  @override
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = '',
    String mimeType = '',
  }) async {}
  @override
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async =>
      TranscriptionJobSnapshot(
        id: 'job',
        requestId: requestId,
        dumpId: dumpId,
        status: 'queued',
        model: model,
      );
  @override
  Future<TranscriptionJobSnapshot> getJob(String jobId) async =>
      throw UnimplementedError();
  @override
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) async* {}
}

/// Subclass that fakes the active+queued state without touching the
/// network.
class _QueuedService extends ServerTranscriptionService {
  _QueuedService({required super.db, required super.audioStorage})
      : super(
          client: _FakeClient(),
        );

  @override
  ServerTranscriptionOperation get operation =>
      const ServerTranscriptionOperation(
        status: ServerTranscriptionStatus.uploading,
        dumpId: 'active',
        startedAt: null,
      );

  @override
  ServerTranscriptionOperation operationFor(
    String dumpId, {
    DumpRow? currentRow,
  }) =>
      switch (dumpId) {
        'active' => operation,
        'queued' => const ServerTranscriptionOperation(
            status: ServerTranscriptionStatus.queued,
            dumpId: 'queued',
          ),
        _ => const ServerTranscriptionOperation.idle(),
      };
}

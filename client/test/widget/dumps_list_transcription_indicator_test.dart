// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/services/local_transcription_coordinator.dart';
import 'package:tangent/services/on_device_transcription.dart';

void main() {
  testWidgets('Dumps list identifies the recording being transcribed',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('tangent-list-progress-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final coordinator = _LoadingCoordinator(db: db, audioStorage: storage);
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });

    await db.upsertDump(_row('active', 'Currently processing'));
    await db.upsertDump(_row('other', 'Another recording'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          localTranscriptionCoordinatorProvider.overrideWith(
            (ref) => coordinator,
          ),
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
    expect(find.text('Loading model locally…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('transcription-indicator-other')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

DumpRow _row(String id, String title) => DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
      mode: 'brain_dump',
      durationSeconds: 9,
      title: title,
      audioPath: 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
    );

final class _LoadingCoordinator extends LocalTranscriptionCoordinator {
  _LoadingCoordinator({required super.db, required super.audioStorage})
      : super(service: _UnusedLocalService());

  @override
  LocalTranscriptionOperation get operation => LocalTranscriptionOperation(
        status: LocalTranscriptionStatus.running,
        dumpId: 'active',
        startedAt: DateTime.utc(2026, 9, 14),
        progress: const LocalTranscriptionProgress(
          stage: LocalTranscriptionStage.loadingModel,
        ),
      );
}

final class _UnusedLocalService extends OnDeviceTranscriptionService {
  _UnusedLocalService()
      : super(
          decoder: _UnusedDecoder(),
          runtime: _UnusedRuntime(),
          temporaryDirectory: Directory.systemTemp.createTemp,
        );
}

final class _UnusedDecoder implements LocalAudioDecoder {
  @override
  Future<File> decodeToWav(Uint8List source, Directory temporaryDirectory) =>
      throw UnimplementedError();
}

final class _UnusedRuntime implements LocalWhisperRuntime {
  @override
  void cancel() {}
  @override
  Future<void> installModel({required ModelProgressCallback onProgress}) =>
      throw UnimplementedError();
  @override
  Future<bool> isModelInstalled() => throw UnimplementedError();
  @override
  Future<String> transcribe(
    File wav, {
    required ModelLoadedCallback onModelLoaded,
    required InferenceProgressCallback onProgress,
  }) =>
      throw UnimplementedError();
}

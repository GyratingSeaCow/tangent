// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/audio_storage.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/local_transcription_coordinator.dart';
import 'package:tangent/services/on_device_transcription.dart';

void main() {
  test('meeting transcription saves raw transcript and secretary notes',
      () async {
    final fixture = await _fixture(mode: 'meeting');
    addTearDown(fixture.dispose);

    await fixture.coordinator.transcribeDump(fixture.row.id);

    final saved = await fixture.db.getDump(fixture.row.id);
    expect(saved!.transcript, 'Alice will send minutes by Friday.');
    expect(saved.meetingNotes, contains('## Action Items'));
    expect(saved.meetingNotes, contains('Owner: Alice; Date: Friday'));
    final sidecar = jsonDecode(
      fixture.storage.metaPathFor(fixture.row.id).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(sidecar['transcript'], saved.transcript);
    expect(sidecar['meetingNotes'], saved.meetingNotes);
  });

  test('brain dump transcription does not generate meeting notes', () async {
    final fixture = await _fixture(mode: 'brain_dump');
    addTearDown(fixture.dispose);

    await fixture.coordinator.transcribeDump(fixture.row.id);

    final saved = await fixture.db.getDump(fixture.row.id);
    expect(saved!.transcript, 'Alice will send minutes by Friday.');
    expect(saved.meetingNotes, isNull);
  });
}

Future<_Fixture> _fixture({required String mode}) async {
  final temp = Directory.systemTemp.createTempSync('tangent-meeting-flow-');
  final db = LocalDb.forTesting(NativeDatabase.memory());
  final storage = AudioStorage.test(temp);
  final row = DumpRow(
    id: 'flow-$mode',
    createdAt: DateTime.utc(2026, 9, 14),
    updatedAt: DateTime.utc(2026, 9, 14),
    mode: mode,
    durationSeconds: 5,
    title: 'Flow test',
    audioPath: storage.pathFor('flow-$mode').path,
    audioSizeBytes: 3,
    syncStatus: 'pending',
    syncAttempts: 0,
  );
  await db.upsertDump(row);
  storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
  return _Fixture(
    temp,
    db,
    storage,
    row,
    LocalTranscriptionCoordinator(
      service: _ImmediateService(),
      db: db,
      audioStorage: storage,
    ),
  );
}

final class _Fixture {
  const _Fixture(
    this.temp,
    this.db,
    this.storage,
    this.row,
    this.coordinator,
  );
  final Directory temp;
  final LocalDb db;
  final AudioStorage storage;
  final DumpRow row;
  final LocalTranscriptionCoordinator coordinator;

  Future<void> dispose() async {
    coordinator.dispose();
    await db.close();
    temp.deleteSync(recursive: true);
  }
}

final class _ImmediateService extends OnDeviceTranscriptionService {
  _ImmediateService()
      : super(
          decoder: _UnusedDecoder(),
          runtime: _UnusedRuntime(),
          temporaryDirectory: Directory.systemTemp.createTemp,
        );

  @override
  Future<String> transcribe(
    Uint8List audio, {
    required LocalTranscriptionProgressCallback onProgress,
  }) async =>
      'Alice will send minutes by Friday.';
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

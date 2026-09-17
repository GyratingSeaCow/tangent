// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';

StorageLocation fileLocation(String id, String path) => (
      id: id,
      label: id,
      directory: (
        kind: 'file',
        path: path,
        treeUri: '',
        authority: '',
        documentId: ''
      ),
    );
Future<T> settled<T>(IoOperation<T> operation) async {
  try {
    return await operation.result;
  } finally {
    await operation.settled;
  }
}

T requireOk<T>(Outcome<T> result) => switch (result) {
      Ok<T>(:final value) => value,
      Fail<T>(:final problem) => throw StorageFault(problem),
    };

final class StorageFixture {
  StorageFixture._(this.root, this.db);
  factory StorageFixture.create() {
    final root =
        Directory.systemTemp.createTempSync('tangent-storage-fixture-');
    for (final name in ['A', 'B', 'stage']) {
      Directory(p.join(root.path, name)).createSync();
    }
    return StorageFixture._(
      root,
      LocalDb.forTesting(
        NativeDatabase(File(p.join(root.path, 'fixture.sqlite'))),
      ),
    );
  }
  final Directory root;
  LocalDb db;
  final StorageBackend backend = FilesystemStorageBackend();
  Future<void> reopen() async {
    await backend.drain();
    await db.close();
    db = LocalDb.forTesting(
      NativeDatabase(File(p.join(root.path, 'fixture.sqlite'))),
    );
  }

  String directory(String name) => p.join(root.path, name);
  File audio(String folder, String id) =>
      File(p.join(directory(folder), '$id.opus'));
  File metadata(String folder, String id) =>
      File(p.join(directory(folder), '$id.meta.json'));
  Future<BoundRecording> seed(
    String id, {
    String folder = 'A',
    String status = 'not_transcribed',
    String sync = 'local_only',
    String? error,
  }) async {
    if (!id.startsWith('fixture-')) throw ArgumentError('Synthetic IDs only');
    final location = fileLocation(folder, directory(folder));
    final bytes = [1, 2, 3];
    await audio(folder, id).writeAsBytes(bytes, flush: true);
    await metadata(folder, id).writeAsString(
      jsonEncode({'schemaVersion': 2, 'id': id, 'title': id}),
      flush: true,
    );
    final now = DateTime.utc(2030, 1, 2);
    final row = DumpRow(
      id: id,
      createdAt: now,
      updatedAt: now,
      mode: 'brain_dump',
      durationSeconds: 3,
      title: id,
      transcript: status == 'completed' ? 'retained words' : null,
      meetingNotes: 'retained notes',
      audioPath: audio(folder, id).path,
      audioSizeBytes: bytes.length,
      syncStatus: sync,
      syncAttempts: 0,
      transcriptionStatus: status,
      transcriptionAttempt: status == 'not_transcribed' ? 0 : 1,
      transcriptionRequestId:
          status == 'not_transcribed' ? null : 'request-$id',
      transcriptionJobId: status == 'running' ? 'job-$id' : null,
      transcriptionError: error,
    );
    await db.into(db.dumps).insert(row);
    await db.customStatement(
        'INSERT OR IGNORE INTO storage_locations(id,canonical_key,directory_json,label) VALUES(?,?,?,?)',
        [
          folder,
          StorageCodec.canonicalKey(location.directory),
          StorageCodec.encodeDirectory(location.directory),
          folder,
        ]);
    await db.customStatement(
        'INSERT INTO recording_bindings(dump_id,incarnation,location_id,audio_json,metadata_name,resolved) VALUES(?,?,?,?,?,1)',
        [
          id,
          'incarnation-$id',
          folder,
          StorageCodec.encodeAudio((kind: 'file', value: row.audioPath)),
          '$id.meta.json',
        ]);
    return (
      key: (dumpId: id, incarnation: 'incarnation-$id'),
      location: location,
      audio: (kind: 'file', value: row.audioPath),
      metadataName: '$id.meta.json'
    );
  }

  Future<void> close() async {
    await backend.drain();
    await db.close();
    await root.delete(recursive: true);
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
/// Downloading a synced recording's audio, as the database and the user's
/// folder actually see it.
///
/// A remote-only recording carries metadata and a transcript but no audio:
/// `remote_only = 1`, an empty `audio_path`, and `audio_on_server = 1` when
/// the server holds the bytes. Downloading has to end with a row that PLAYS,
/// which means more than writing a file — `resolveRecording` faults with
/// 'Original storage is unresolved' unless a binding row exists, so a
/// download that only sets `audio_path` produces a recording that looks
/// available and refuses to open.
///
/// These tests pin the whole sequence: publish into the user's folder through
/// the storage port (never a direct write), attach, bind, and leave the row
/// playable — plus the failure paths, where a half-finished download must not
/// strand a row claiming audio it does not have.
library;

import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/synced_audio_download.dart';

import '../../support/storage_fixture.dart';

/// Real opus-ish bytes: a short binary blob containing values that are NOT
/// valid UTF-8, so a text publication path would corrupt or reject them.
final Uint8List _audioBytes = Uint8List.fromList(<int>[
  0x4F, 0x67, 0x67, 0x53, // 'OggS'
  0x00, 0xFF, 0xFE, 0x80, 0x81, 0x00, 0x01, 0x02,
  0xC0, 0xC1, 0xF5, 0xFF, // invalid UTF-8 continuation bytes
  ...List<int>.filled(64, 0xAB),
]);

class _FakeDownloader {
  _FakeDownloader(this.bytes, {this.failWith});

  final Uint8List bytes;
  final Object? failWith;
  int calls = 0;

  Future<List<int>> download(String dumpId) async {
    calls++;
    if (failWith != null) throw failWith!;
    return bytes;
  }
}

void main() {
  late Directory root;
  late LocalDb db;
  late FilesystemStorageBackend backend;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tangent-dl');
    db = LocalDb.forTesting(NativeDatabase.memory());
    backend = FilesystemStorageBackend();
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Seeds a remote-only recording: metadata synced, audio still on the
  /// server. This is exactly what `applyRemoteDump` writes.
  Future<void> seedRemote(String id) async {
    await db.into(db.dumps).insert(
          DumpsCompanion.insert(
            id: id,
            createdAt: DateTime.utc(2026, 9, 18),
            updatedAt: DateTime.utc(2026, 9, 18),
            mode: 'brain_dump',
            durationSeconds: 12,
            title: 'From the other device',
            audioPath: '',
            audioSizeBytes: 0,
            syncStatus: 'synced',
            transcript: const Value<String?>('the transcript came across'),
            remoteOnly: const Value<bool?>(true),
            audioOnServer: const Value<bool?>(true),
          ),
        );
  }

  /// The user's selected folder, persisted the way the fixtures do it.
  /// Registering the row matters: `bindRecording` rejects a binding whose
  /// location is not the persisted capability.
  Future<StorageLocation> location() async {
    final StorageLocation loc = fileLocation('fixture-synced-audio', root.path);
    final String canonical = StorageCodec.canonicalKey(loc.directory);
    await db.customStatement(
      'INSERT OR IGNORE INTO storage_locations(id,canonical_key,directory_json,label) '
      'VALUES(?,?,?,?)',
      <Object?>[
        loc.id,
        canonical,
        StorageCodec.encodeDirectory(loc.directory),
        loc.label,
      ],
    );
    return loc;
  }

  test('downloaded audio lands in the synced-audio folder, byte-exact',
      () async {
    await seedRemote('dump-0001');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
    );

    final Outcome<String> result = await downloader.download('dump-0001');
    expect(result, isA<Ok<String>>());

    // The file is in the dedicated child, not the folder root: the root holds
    // what THIS device captured.
    final Directory synced =
        Directory('${root.path}/$syncedAudioSubdirectoryName');
    expect(
      synced.existsSync(),
      isTrue,
      reason: 'the synced-audio child directory must be created',
    );

    final File published = File('${synced.path}/dump-0001.opus');
    expect(published.existsSync(), isTrue);
    expect(
      published.readAsBytesSync(),
      _audioBytes,
      reason: 'audio must survive publication byte-for-byte',
    );
  });

  test('a downloaded recording is playable, not merely present', () async {
    await seedRemote('dump-0002');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
    );

    await downloader.download('dump-0002');

    // The binding is what playback resolves through. Without it the row looks
    // downloaded and refuses to open.
    final BoundRecording? binding = await db.boundRecording('dump-0002');
    expect(
      binding,
      isNotNull,
      reason: 'no binding means resolveRecording faults as unresolved',
    );
    expect(binding!.key.dumpId, 'dump-0002');

    // A binding row alone once passed this test while the device said
    // "Playback unavailable: absent" — the resolvers only accepted the root
    // and the text-note child, not 'Tangent Synced Audio'. Resolving through
    // the REAL backend is the assertion that actually matches the device.
    final Outcome<Uint8List> read = await backend.readAudio(binding).result;
    expect(
      read,
      isA<Ok<Uint8List>>(),
      reason: 'the backend must resolve audio inside Tangent Synced Audio',
    );
    expect(
      (read as Ok<Uint8List>).value,
      _audioBytes,
      reason: 'resolution must reach the exact downloaded bytes',
    );
    final Outcome<AudioLocator> source =
        await backend.playbackSource(binding).result;
    expect(
      source,
      isA<Ok<AudioLocator>>(),
      reason: 'playbackSource is the path the detail screen actually takes',
    );

    final DumpRow row = (await db.getDumpRow('dump-0002'))!;
    expect(
      row.remoteOnly,
      isNot(true),
      reason: 'the audio is local now, so the row is no longer remote-only',
    );
    expect(row.audioPath, isNotEmpty);
    expect(row.audioSizeBytes, _audioBytes.length);
  });

  test('metadata and transcript are never disturbed by a download', () async {
    await seedRemote('dump-0003');
    final DumpRow before = (await db.getDumpRow('dump-0003'))!;
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: _FakeDownloader(_audioBytes).download,
    );

    await downloader.download('dump-0003');

    final DumpRow after = (await db.getDumpRow('dump-0003'))!;
    expect(after.title, before.title);
    expect(after.transcript, before.transcript);
    expect(
      after.updatedAt,
      before.updatedAt,
      reason: 'fetching audio is not a user edit',
    );
    expect(
      after.syncDirty,
      isNot(true),
      reason: 'a download must not push anything back to the fleet',
    );
  });

  test('a failed download leaves no row claiming audio it does not have',
      () async {
    await seedRemote('dump-0004');
    final fake = _FakeDownloader(
      _audioBytes,
      failWith: const SocketException('no route to host'),
    );
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
    );

    final Outcome<String> result = await downloader.download('dump-0004');
    expect(result, isA<Fail<String>>());

    final DumpRow row = (await db.getDumpRow('dump-0004'))!;
    expect(
      row.remoteOnly,
      isTrue,
      reason: 'the download failed, so the button must stay available',
    );
    expect(row.audioPath, isEmpty);
    expect(row.audioSizeBytes, 0);
    expect(await db.boundRecording('dump-0004'), isNull);
  });

  test('a server with no audio is reported, not retried forever', () async {
    await seedRemote('dump-0005');
    final fake = _FakeDownloader(
      Uint8List(0),
      failWith: const StorageFault(
        (code: ProblemCode.absent, message: 'Server has no audio'),
      ),
    );
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
    );

    final Outcome<String> result = await downloader.download('dump-0005');
    expect(result, isA<Fail<String>>());
    expect((result as Fail<String>).problem.code, ProblemCode.absent);
  });

  test('a recording that already has local audio is not downloaded again',
      () async {
    await seedRemote('dump-0006');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
    );

    await downloader.download('dump-0006');
    expect(fake.calls, 1);

    // Second attempt: already local, so no network call and no republish.
    final Outcome<String> again = await downloader.download('dump-0006');
    expect(again, isA<Ok<String>>());
    expect(
      fake.calls,
      1,
      reason: 'audio already on disk must not be fetched twice',
    );
  });

  test('an empty response is refused rather than published as a dead file',
      () async {
    await seedRemote('dump-0007');
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: _FakeDownloader(Uint8List(0)).download,
    );

    final Outcome<String> result = await downloader.download('dump-0007');
    expect(result, isA<Fail<String>>());

    final Directory synced =
        Directory('${root.path}/$syncedAudioSubdirectoryName');
    final bool anyFile =
        synced.existsSync() && synced.listSync().whereType<File>().isNotEmpty;
    expect(
      anyFile,
      isFalse,
      reason: 'an empty download must not leave a zero-byte recording',
    );

    final DumpRow row = (await db.getDumpRow('dump-0007'))!;
    expect(row.remoteOnly, isTrue);
  });

  test('Wi-Fi-only refuses an audio fetch on mobile data', () async {
    // Jeff's rule: "Metadata always syncs; only audio fetch respects
    // Wi-Fi-only". A library of recordings would eat a data plan, so the
    // gate belongs HERE and never on the sync engine.
    await seedRemote('dump-0008');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
      wifiOnly: () async => true,
      connection: () async => ConnectivityStatus.mobile,
    );

    final Outcome<String> result = await downloader.download('dump-0008');
    expect(result, isA<Fail<String>>());
    expect(
      fake.calls,
      0,
      reason: 'the gate must stop the fetch BEFORE spending the data',
    );

    final DumpRow row = (await db.getDumpRow('dump-0008'))!;
    expect(row.remoteOnly, isTrue);
  });

  test('Wi-Fi-only allows the fetch on Wi-Fi', () async {
    await seedRemote('dump-0009');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
      wifiOnly: () async => true,
      connection: () async => ConnectivityStatus.wifi,
    );

    expect(await downloader.download('dump-0009'), isA<Ok<String>>());
    expect(fake.calls, 1);
  });

  test('mobile data is fine when the user has not asked for Wi-Fi-only',
      () async {
    await seedRemote('dump-0010');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
      wifiOnly: () async => false,
      connection: () async => ConnectivityStatus.mobile,
    );

    expect(await downloader.download('dump-0010'), isA<Ok<String>>());
    expect(fake.calls, 1);
  });

  test('an offline device is refused whatever the Wi-Fi-only setting says',
      () async {
    await seedRemote('dump-0011');
    final fake = _FakeDownloader(_audioBytes);
    final downloader = SyncedAudioDownloader(
      db: db,
      backend: backend,
      location: await location(),
      fetch: fake.download,
      wifiOnly: () async => false,
      connection: () async => ConnectivityStatus.offline,
    );

    final Outcome<String> result = await downloader.download('dump-0011');
    expect(result, isA<Fail<String>>());
    expect(fake.calls, 0);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import '../data/local_db.dart';
import '../data/storage/storage_contract.dart';
import 'connectivity_service.dart';

/// Fetches one recording's audio bytes from the sync server.
///
/// Injected rather than taking a client directly so the download sequence can
/// be tested without a socket, and so a caller can supply any transport.
typedef SyncedAudioFetch = Future<List<int>> Function(String dumpId);

/// Reads the user's "sync on Wi-Fi only" preference at the moment of the
/// fetch, rather than capturing it once at construction: the user may change
/// it in Settings between opening the list and tapping download.
typedef WifiOnlyPreference = Future<bool> Function();

/// Reads the current connection kind at the moment of the fetch.
typedef ConnectionProbe = Future<ConnectivityStatus> Function();

/// Brings a synced recording's audio down from the server and makes it
/// PLAYABLE on this device.
///
/// A remote-only recording arrives carrying metadata and a transcript but no
/// bytes: `remote_only = 1`, an empty `audio_path`, and `audio_on_server = 1`
/// when the server holds the audio. Downloading is deliberately explicit —
/// audio never travels the change feed, because a library of recordings would
/// saturate a phone's data plan the first time it synced.
///
/// Writing the file is NOT enough. `StorageCatalog.resolveRecording` faults
/// with 'Original storage is unresolved' unless a `recording_bindings` row
/// exists, so a download that only set `audio_path` would produce a recording
/// that looks available and refuses to open. The sequence is therefore:
/// publish through the storage port, attach the path, then bind.
///
/// The bytes are published into [syncedAudioSubdirectoryName] rather than the
/// folder root: the root holds what THIS device captured, and a synced copy
/// of another device's recording is a different thing. Publication goes
/// through the port — never a direct file write — so a downloaded file gets
/// the same ownership checks and atomic replace a capture does.
class SyncedAudioDownloader {
  SyncedAudioDownloader({
    required this.db,
    required this.backend,
    required this.location,
    required this.fetch,
    this.wifiOnly,
    this.connection,
  });

  final LocalDb db;
  final StorageBackend backend;
  final StorageLocation location;
  final SyncedAudioFetch fetch;

  /// Both optional so a caller that has already decided (a test, or a future
  /// "download anyway" confirmation) can skip the gate entirely. When either
  /// is absent the fetch is attempted and the transport reports any failure.
  final WifiOnlyPreference? wifiOnly;
  final ConnectionProbe? connection;

  int _publications = 0;

  Future<T> _settled<T>(IoOperation<T> operation) async {
    try {
      return await operation.result;
    } finally {
      await operation.settled;
    }
  }

  /// Downloads [dumpId]'s audio, publishes it, and binds it for playback.
  ///
  /// Returns the published path on success. A failure NEVER leaves the row
  /// claiming audio it does not have: `remote_only` stays true so the
  /// download affordance remains available and the user can retry.
  Future<Outcome<String>> download(String dumpId) async {
    try {
      final DumpRow? row = await db.getDumpRow(dumpId);
      if (row == null) {
        return const Fail<String>(
          (code: ProblemCode.absent, message: 'Recording is missing'),
        );
      }

      // Already local. Return the existing path rather than refetching: a
      // second download would burn the user's data to overwrite identical
      // bytes, and republishing would churn their folder for nothing.
      if (row.audioPath.isNotEmpty && row.remoteOnly != true) {
        return Ok<String>(row.audioPath);
      }

      // Gate BEFORE spending the user's data. Metadata always syncs; this
      // setting governs only the audio fetch, which is the expensive part.
      final Outcome<void>? refusal = await _refusal();
      if (refusal is Fail<void>) {
        return Fail<String>(refusal.problem);
      }

      final List<int> bytes = await fetch(dumpId);
      if (bytes.isEmpty) {
        // A zero-byte recording is worse than none: it publishes a file that
        // looks downloaded and plays as nothing.
        return const Fail<String>(
          (
            code: ProblemCode.invalid,
            message: 'The server returned no audio for this recording',
          ),
        );
      }

      final String name = '$dumpId${_extensionFor(row.mode)}';
      final DurableDocument published = _value(
        await _settled(
          backend.publishBinaryDocument(
            location,
            syncedAudioSubdirectoryName,
            name,
            Uint8List.fromList(bytes),
            _mimeFor(name),
            'synced-audio-$dumpId-${_publications++}',
          ),
        ),
      );

      // Attach BEFORE binding: bindRecording verifies the dump's audio_path
      // already equals the binding's locator, and rejects the binding as
      // 'Original audio identity differs' otherwise.
      await db.attachDownloadedAudio(
        dumpId,
        audioPath: published.locator.value,
        audioSizeBytes: bytes.length,
      );

      try {
        await db.bindRecording(
          (
            key: (dumpId: dumpId, incarnation: 'synced-$dumpId'),
            location: location,
            audio: published.locator,
            metadataName: '$dumpId.meta.json',
          ),
        );
      } on StorageFault {
        // An attached path with no binding is the unplayable state this
        // service exists to prevent. Put the row back the way it was so the
        // download can be retried cleanly.
        await _revert(dumpId);
        rethrow;
      }

      return Ok<String>(published.locator.value);
    } on StorageFault catch (fault) {
      await _revert(dumpId);
      return Fail<String>(fault.problem);
    } catch (error) {
      await _revert(dumpId);
      return Fail<String>(
        (code: ProblemCode.io, message: error.toString()),
      );
    }
  }

  /// Decides whether this fetch may proceed, or `null` when unconstrained.
  ///
  /// Returns a [Fail] carrying wording the UI shows verbatim — the reason a
  /// control is unavailable belongs next to the control, not in a log.
  Future<Outcome<void>?> _refusal() async {
    final ConnectionProbe? probe = connection;
    if (probe == null) return null;

    final ConnectivityStatus status = await probe();
    if (!status.isOnline) {
      return const Fail<void>(
        (
          code: ProblemCode.unavailable,
          message: 'No connection. Audio downloads need the server.',
        ),
      );
    }

    final WifiOnlyPreference? preference = wifiOnly;
    if (preference == null) return null;
    if (await preference() && status != ConnectivityStatus.wifi) {
      return const Fail<void>(
        (
          code: ProblemCode.unavailable,
          message: 'Wi-Fi only: connect to Wi-Fi to download audio.',
        ),
      );
    }
    return null;
  }

  /// Returns the row to remote-only after a failed download, so the UI keeps
  /// offering the fetch instead of showing a recording that cannot play.
  Future<void> _revert(String dumpId) async {
    try {
      await db.clearDownloadedAudio(dumpId);
    } catch (_) {
      // Best effort: the row is already in the failed state the caller sees.
    }
  }

  T _value<T>(Outcome<T> result) => switch (result) {
        Ok<T>(:final T value) => value,
        Fail<T>(:final StorageProblem problem) => throw StorageFault(problem),
      };

  /// Audio modes publish `.opus`; a text note has no audio to download.
  String _extensionFor(String mode) => '.opus';

  /// An Opus file is an Ogg container, which is what the SAF layer must be
  /// told — declaring a MIME that disagrees with the extension makes AOSP
  /// rename the file (a `.wav` declared `audio/ogg` was published as
  /// `.wav.oga`, at zero bytes and invisible to the app).
  String _mimeFor(String name) =>
      name.endsWith('.wav') ? 'audio/wav' : 'audio/ogg';
}

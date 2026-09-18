// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:just_audio/just_audio.dart';

import '../data/local_db.dart';
import '../data/storage/storage_contract.dart';
import '../services/recording_persistence.dart';
import '../services/recording_service.dart';

/// Reads the playable duration of an audio file, in whole seconds.
typedef AudioDurationProbe = Future<int> Function(String path);

/// Real duration probe, backed by the same player the app uses for playback.
///
/// A file that cannot be opened reports 0 rather than throwing: an odd
/// duration is a cosmetic problem, and refusing the import outright over it
/// would be worse than showing 0:00 for a file that still plays.
Future<int> probeAudioDuration(String path) async {
  final AudioPlayer player = AudioPlayer();
  try {
    final Duration? duration = await player.setFilePath(path);
    return duration?.inSeconds ?? 0;
  } catch (_) {
    return 0;
  } finally {
    await player.dispose();
  }
}

/// Brings an existing audio file into the Tangent catalog.
///
/// Jeff: "There also needs to be an Import Audio button which will allow you
/// to import audio into the tangent folder by copying it to the tangent
/// folder and then processing it".
///
/// The import deliberately reuses the live-capture path -- reserve a capture,
/// write the bytes into that reservation's staging slot, then publish through
/// [RecordingPersistence.save] -- rather than writing into the recordings
/// folder directly. That is what earns an import the same ownership checks,
/// the same atomic publish and the same crash-safety a recording gets; a file
/// dropped straight into the folder would be adopted by scan with none of it.
///
/// The source is copied, never moved: the user's original file stays exactly
/// where it was.
class AudioImporter {
  AudioImporter({
    required this.catalog,
    required this.backend,
    required this.db,
    required this.mutations,
    required this.durationOf,
  });

  final StorageCatalog catalog;
  final StorageBackend backend;
  final LocalDb db;
  final RecordingMutationCoordinator mutations;
  final AudioDurationProbe durationOf;

  /// Copies [sourcePath] into the recordings folder as a new dump.
  ///
  /// Returns the new dump id, or a [Fail] describing why it could not be
  /// imported. A failure never leaves a completed row behind: the reservation
  /// is abandoned the same way an interrupted capture is.
  Future<Outcome<String>> import({
    required String sourcePath,
    required String mode,
    String? title,
  }) async {
    final File source = File(sourcePath);

    // Check the source BEFORE reserving, so a bad pick costs nothing.
    if (!source.existsSync()) {
      return const Fail(
        (code: ProblemCode.invalid, message: 'That file no longer exists'),
      );
    }
    final int sizeBytes = await source.length();
    if (sizeBytes <= 0) {
      return const Fail(
        (code: ProblemCode.invalid, message: 'That file is empty'),
      );
    }

    final Outcome<CaptureReservation> reserved =
        await catalog.reserveCapture(mode: mode);
    if (reserved is! Ok<CaptureReservation>) {
      return Fail((reserved as Fail<CaptureReservation>).problem);
    }
    final CaptureReservation reservation = reserved.value;

    UseLease? lease;
    try {
      // Copy into the reservation's staging slot. The name is fixed by the
      // reservation, so the published component is owned exactly like a
      // recorded one.
      await source.copy(reservation.stagingPath);

      final int duration = await durationOf(reservation.stagingPath);

      final Outcome<UseLease> acquired = await mutations.acquire(
        reservation.key.dumpId,
        UseKind.capture,
        expectedIncarnation: reservation.key.incarnation,
      );
      if (acquired is! Ok<UseLease>) {
        return Fail((acquired as Fail<UseLease>).problem);
      }
      final UseLease held = acquired.value;
      lease = held;

      final row = await mutations.serialize(
        reservation.key,
        () => RecordingPersistence(
          db: db,
          backend: backend,
          mutations: mutations,
        ).save(
          reservation,
          RecordingResult(
            path: reservation.stagingPath,
            durationSeconds: duration,
            sizeBytes: sizeBytes,
          ),
          now: DateTime.now().toUtc(),
          lease: held,
        ),
      );

      if (title != null && title.isNotEmpty) {
        await (db.update(db.dumps)..where((t) => t.id.equals(row.id)))
            .write(DumpsCompanion(title: Value(title)));
      }

      return Ok(row.id);
    } on StorageFault catch (fault) {
      await _abandon(reservation);
      return Fail(fault.problem);
    } on FileSystemException catch (error) {
      await _abandon(reservation);
      return Fail(
        (
          code: ProblemCode.io,
          message: error.message,
        ),
      );
    } finally {
      await lease?.close();
    }
  }

  /// Drops a reservation whose import failed, so a retry is not blocked by a
  /// half-made capture and no staging file is left behind.
  Future<void> _abandon(CaptureReservation reservation) async {
    try {
      final File staged = File(reservation.stagingPath);
      if (staged.existsSync()) await staged.delete();
    } on FileSystemException {
      // Staging cleanup is best effort; the reservation row below is what
      // actually gates a retry.
    }
    try {
      await db.customStatement(
        'DELETE FROM capture_reservations WHERE reservation_id = ?',
        <Object?>[reservation.id],
      );
    } catch (_) {
      // Leaving the row is survivable: startup recovery reclaims abandoned
      // reservations.
    }
  }
}

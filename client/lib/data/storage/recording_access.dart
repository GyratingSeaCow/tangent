// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../local_db.dart';
import '../../services/recording_playback.dart';
import 'storage_contract.dart';

T _require<T>(Outcome<T> result) => switch (result) {
      Ok<T>(:final value) => value,
      Fail<T>(:final problem) => throw StorageFault(problem),
    };

class BoundRecordingAccess implements RecordingAccess {
  BoundRecordingAccess({
    required LocalDb db,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
  })  : _db = db,
        _backend = backend,
        _mutations = mutations;
  final LocalDb _db;
  final StorageBackend _backend;
  final RecordingMutationCoordinator _mutations;
  Future<UseLease> _acquire(RecordingKey key, UseKind kind) async => _require(
        await _mutations.acquire(
          key.dumpId,
          kind,
          expectedIncarnation: key.incarnation,
        ),
      );
  @override
  Future<Outcome<AudioReadLease>> openAudio(RecordingKey key) async {
    try {
      return Ok(
        _ReadLease(await _acquire(key, UseKind.read), _backend, _mutations),
      );
    } on StorageFault catch (e) {
      return Fail(e.problem);
    }
  }

  @override
  Future<Outcome<PlaybackLease>> openPlayback(
    RecordingKey key,
    RecordingPlaybackEngine engine,
  ) async {
    UseLease? use;
    try {
      use = await _acquire(key, UseKind.playback);
      final source = _require(
        await _mutations.runIo(
          use,
          () => _backend.playbackSource(use!.binding!),
        ),
      );
      return Ok(_PlaybackLease(use, source, engine));
    } on StorageFault catch (e) {
      if (use != null) unawaited(use.close());
      return Fail(e.problem);
    } catch (_) {
      if (use != null) unawaited(use.close());
      rethrow;
    }
  }

  @override
  Future<T> runSerializedMetadataWrite<T>(
    RecordingKey key,
    Future<T> Function(MetadataPublicationAccess access) operation,
  ) async {
    final lease = await _acquire(key, UseKind.publication);
    try {
      return await _mutations.serialize(key, () async {
        try {
          if (!await _db.mutationAllowed(key)) {
            throw const StorageFault(
              (
                code: ProblemCode.fenced,
                message: 'Publication ownership changed'
              ),
            );
          }
          return await operation(_Writer(lease, _backend, _mutations));
        } finally {
          await lease.close();
        }
      });
    } finally {
      await lease.close();
    }
  }
}

class _ReadLease implements AudioReadLease {
  _ReadLease(this.use, this.backend, this.mutations);
  final UseLease use;
  final StorageBackend backend;
  final RecordingMutationCoordinator mutations;
  @override
  RecordingKey get key => use.key;
  @override
  Future<Uint8List> read() async => _require(
        await mutations.runIo(use, () => backend.readAudio(use.binding!)),
      );
  @override
  Future<void> close() => use.close();
}

class _Writer implements MetadataPublicationAccess {
  _Writer(this.use, this.backend, this.mutations);
  final UseLease use;
  final StorageBackend backend;
  final RecordingMutationCoordinator mutations;
  @override
  BoundRecording get binding => use.binding!;
  @override
  Future<void> write(Map<String, dynamic> metadata) async {
    _require(
      await mutations.runIo(
        use,
        () => backend.writeMetadata(binding, metadata, const Uuid().v4()),
      ),
    );
  }
}

class _PlaybackLease implements PlaybackLease {
  _PlaybackLease(this.use, this.source, RecordingPlaybackEngine raw)
      : engine = _ProtectedPlayer(use, source, raw);
  final UseLease use;
  @override
  final AudioLocator source;
  @override
  final RecordingPlaybackEngine engine;
  @override
  RecordingKey get key => use.key;
  @override
  Future<void> close() => engine.dispose();
}

/// Closing rejects new loads immediately, then awaits disposal AND prior loads.
class _ProtectedPlayer implements RecordingPlaybackEngine {
  _ProtectedPlayer(this.use, this.source, this.raw);
  final UseLease use;
  final AudioLocator source;
  final RecordingPlaybackEngine raw;
  final _loads = <Future<void>>{};
  Future<void>? _closing;
  bool _closed = false;
  void _check() {
    if (_closed) {
      throw const StorageFault(
        (code: ProblemCode.fenced, message: 'Playback is closing'),
      );
    }
  }

  @override
  Stream<Duration> get positionStream => raw.positionStream;
  @override
  Stream<Duration?> get durationStream => raw.durationStream;
  @override
  Stream<bool> get playingStream => raw.playingStream;
  @override
  Stream<bool> get completedStream => raw.completedStream;
  @override
  Future<Duration?> load(AudioLocator requested) async {
    _check();
    if (requested != source) {
      throw const StorageFault(
        (
          code: ProblemCode.invalid,
          message: 'Playback source differs from bound source'
        ),
      );
    }

    final done = Completer<void>();
    _loads.add(done.future);
    try {
      return await raw.load(source);
    } finally {
      _loads.remove(done.future);
      done.complete();
    }
  }

  @override
  Future<void> play() {
    _check();
    return raw.play();
  }

  @override
  Future<void> pause() {
    _check();
    return raw.pause();
  }

  @override
  Future<void> seek(Duration position) {
    _check();
    return raw.seek(position);
  }

  @override
  Future<void> dispose() {
    _closed = true;
    return _closing ??= () async {
      // A failed disposal leaves the lease protected: no proof the engine stopped.
      await raw.dispose();
      await Future.wait(_loads.toList());
      await use.close();
    }();
  }
}

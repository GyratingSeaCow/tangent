// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Durable recording storage.
///
/// Android uses a user-selected Storage Access Framework folder, never an
/// app-private fallback. The recorder writes to [_stagingDir] first because
/// Android's recorder API needs a filesystem path; [persistRecording] then
/// copies and fsyncs audio + metadata into the selected public folder before
/// deleting the staging file.
class AudioStorage {
  static const _channel = MethodChannel('dev.tangent.tangent/storage');
  static const _audioExt = '.opus';
  static const _metaExt = '.meta.json';

  final Directory _stagingDir;
  final Directory? _filesystemDir;
  bool _ready;
  final Map<String, Future<void>> _metadataWriteTails = {};

  AudioStorage._(this._stagingDir, this._filesystemDir, this._ready);

  factory AudioStorage.test(Directory baseDir) {
    final durable = Directory(p.join(baseDir.path, 'Tangent'));
    final staging = Directory(p.join(baseDir.path, '.staging'));
    durable.createSync(recursive: true);
    staging.createSync(recursive: true);
    return AudioStorage._(staging, durable, true);
  }

  static Future<AudioStorage> resolve({
    required Directory durableDirectory,
    required Directory stagingDirectory,
  }) async {
    await stagingDirectory.create(recursive: true);
    if (!Platform.isAndroid) {
      final durable = Directory(p.join(durableDirectory.path, 'Tangent'));
      await durable.create(recursive: true);
      return AudioStorage._(stagingDirectory, durable, true);
    }
    final ready =
        await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;
    return AudioStorage._(stagingDirectory, null, ready);
  }

  bool get isReady => _ready;
  Directory get stagingDir => _stagingDir;

  /// Only available to filesystem-backed tests and non-Android platforms.
  Directory get audioDir =>
      _filesystemDir ??
      (throw StateError('Android durable storage is a SAF document tree'));
  String get audioDirPath => audioDir.path;

  Future<bool> requestAccess() async {
    if (!Platform.isAndroid) return _ready;
    _ready = await _channel.invokeMethod<bool>('chooseStorageFolder') ?? false;
    return _ready;
  }

  File stagingPathFor(String id) =>
      File(p.join(_stagingDir.path, '$id$_audioExt'));
  File pathFor(String id) => File(p.join(audioDir.path, '$id$_audioExt'));
  File metaPathFor(String id) => File(p.join(audioDir.path, '$id$_metaExt'));

  Future<StoredAudio> persistRecording({
    required String id,
    required String temporaryPath,
    required Map<String, dynamic> metadata,
  }) async {
    final source = File(temporaryPath);
    if (!await source.exists()) {
      throw AudioStorageException(
        'Recording staging file is missing: $temporaryPath',
      );
    }
    final size = await source.length();
    if (size <= 0) {
      throw const AudioStorageException(
        'Recorder produced an empty file; the staging file was kept for recovery',
      );
    }
    if (!_ready) {
      throw const AudioStorageException(
        'No durable recording folder is authorized. Select Documents or Tangent first.',
      );
    }

    StoredAudio stored;
    if (_filesystemDir != null) {
      final audio = pathFor(id);
      final audioTmp = File('${audio.path}.tmp');
      await source.openRead().pipe(audioTmp.openWrite(mode: FileMode.write));
      await audioTmp.rename(audio.path);
      await _writeMetadataFile(id, metadata);
      stored =
          StoredAudio(locator: audio.path, sizeBytes: await audio.length());
    } else {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'persistRecording',
        {
          'id': id,
          'sourcePath': temporaryPath,
          'metadataJson': jsonEncode(metadata),
        },
      );
      if (result == null ||
          result['uri'] == null ||
          result['sizeBytes'] == null) {
        throw const AudioStorageException(
          'Android did not confirm durable storage',
        );
      }
      stored = StoredAudio(
        locator: result['uri'] as String,
        sizeBytes: (result['sizeBytes'] as num).toInt(),
      );
    }
    await source.delete();
    return stored;
  }

  /// Runs a complete sidecar mutation under a per-recording lock.
  ///
  /// A caller that owns a database barrier must perform its guarded row read,
  /// raw write, and barrier clear or failure update inside [operation]. A
  /// queued operation therefore reads state only after older writers release
  /// ownership.
  Future<T> runSerializedMetadataWrite<T>(
    String id,
    Future<T> Function(
      Future<void> Function(Map<String, dynamic> metadata) write,
    ) operation,
  ) {
    final previous = _metadataWriteTails[id] ?? Future<void>.value();
    final result = Completer<T>();
    late final Future<void> tail;
    tail = previous.then((_) async {
      try {
        final value = await operation(
          (metadata) => _writeMetadataNow(id, metadata),
        );
        result.complete(value);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    _metadataWriteTails[id] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_metadataWriteTails[id], tail)) {
          _metadataWriteTails.remove(id);
        }
      }),
    );
    return result.future;
  }

  Future<void> writeMetadata(String id, Map<String, dynamic> metadata) {
    return runSerializedMetadataWrite<void>(
      id,
      (write) => write(metadata),
    );
  }

  Future<void> _writeMetadataNow(
    String id,
    Map<String, dynamic> metadata,
  ) async {
    if (!_ready) {
      throw const AudioStorageException('Durable storage is unavailable');
    }
    if (_filesystemDir != null) {
      await _writeMetadataFile(id, metadata);
    } else {
      await _channel.invokeMethod<void>(
        'writeMetadata',
        {'id': id, 'metadataJson': jsonEncode(metadata)},
      );
    }
  }

  Future<void> _writeMetadataFile(
    String id,
    Map<String, dynamic> metadata,
  ) async {
    final target = metaPathFor(id);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(metadata), flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
  }

  Future<Uint8List> readBytes(String id) async {
    if (_filesystemDir != null) return pathFor(id).readAsBytes();
    final bytes =
        await _channel.invokeMethod<Uint8List>('readAudio', {'id': id});
    if (bytes == null || bytes.isEmpty) {
      throw AudioStorageException('Durable audio is missing or empty for $id');
    }
    return bytes;
  }

  Future<int> getSize(String id) async {
    try {
      return (await readBytes(id)).length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> deleteFile(String id) async {
    if (_filesystemDir != null) {
      final audio = pathFor(id);
      if (await audio.exists()) await audio.delete();
      final meta = metaPathFor(id);
      if (await meta.exists()) await meta.delete();
      return;
    }
    await _channel.invokeMethod<void>('deleteRecording', {'id': id});
  }

  Future<List<ImportedAudio>> listAll() async {
    if (!_ready) return [];
    if (_filesystemDir != null) {
      if (!await audioDir.exists()) return [];
      final result = <ImportedAudio>[];
      await for (final entity in audioDir.list()) {
        if (entity is! File || !entity.path.endsWith(_audioExt)) continue;
        final id = p.basenameWithoutExtension(entity.path);
        final metaFile = metaPathFor(id);
        Map<String, dynamic>? metadata;
        if (await metaFile.exists()) {
          try {
            metadata = jsonDecode(await metaFile.readAsString())
                as Map<String, dynamic>;
          } catch (_) {
            metadata = null;
          }
        }
        result.add(
          ImportedAudio(
            id: id,
            locator: entity.path,
            sizeBytes: await entity.length(),
            modifiedAt: await entity.lastModified(),
            metadata: metadata,
          ),
        );
      }
      return result;
    }

    final rows =
        await _channel.invokeListMethod<dynamic>('listRecordings') ?? const [];
    return rows.map((raw) {
      final map = Map<Object?, Object?>.from(raw as Map);
      Map<String, dynamic>? metadata;
      final metadataJson = map['metadataJson'] as String?;
      if (metadataJson != null) {
        try {
          metadata = jsonDecode(metadataJson) as Map<String, dynamic>;
        } catch (_) {
          metadata = null;
        }
      }
      return ImportedAudio(
        id: map['id'] as String,
        locator: map['uri'] as String,
        sizeBytes: (map['sizeBytes'] as num).toInt(),
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(
          (map['lastModified'] as num).toInt(),
          isUtc: true,
        ),
        metadata: metadata,
      );
    }).toList();
  }
}

class StoredAudio {
  final String locator;
  final int sizeBytes;
  const StoredAudio({required this.locator, required this.sizeBytes});
}

class ImportedAudio {
  final String id;
  final String locator;
  final int sizeBytes;
  final DateTime modifiedAt;
  final Map<String, dynamic>? metadata;

  const ImportedAudio({
    required this.id,
    required this.locator,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.metadata,
  });
}

class AudioStorageException implements Exception {
  final String message;
  const AudioStorageException(this.message);
  @override
  String toString() => 'AudioStorageException: $message';
}

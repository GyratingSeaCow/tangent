// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'storage_codec.dart';
import 'storage_contract.dart';

/// Explicit-root operations. The caller owns admission/publication leases.
class FilesystemStorageBackend implements StorageBackend {
  static int _sequence = 0;
  final Set<Future<void>> _pending = {};
  IoOperation<T> _run<T>(Future<T> Function() action) {
    final operation = _FileOperation<T>(
      'file-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      action,
    );
    _pending.add(operation.settled);
    unawaited(
      operation.settled.then((_) => _pending.remove(operation.settled)),
    );
    return operation;
  }

  Future<Outcome<T>> _outcome<T>(Future<T> Function() action) async {
    try {
      return Ok(await action());
    } on StorageFault catch (e) {
      return Fail(e.problem);
    } on FileSystemException catch (e) {
      return Fail((code: ProblemCode.io, message: e.message));
    } on FormatException {
      return const Fail(
        (code: ProblemCode.invalid, message: 'Malformed metadata'),
      );
    }
  }

  Never _invalid(String message) =>
      throw StorageFault((code: ProblemCode.invalid, message: message));
  Future<String> _root(StorageLocation location) async {
    StorageCodec.encodeLocation(location);
    if (location.directory.kind != 'file') {
      _invalid('Expected a filesystem root');
    }
    final path = location.directory.path;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const StorageFault(
        (
          code: ProblemCode.unavailable,
          message: 'Authorized root is unavailable or is a link'
        ),
      );
    }
    final resolved = await Directory(path).resolveSymbolicLinks();
    if (!p.equals(p.normalize(path), resolved)) {
      _invalid('Linked root ancestry is not supported');
    }
    return resolved;
  }

  Future<String> _component(
    BoundRecording binding,
    RecordingComponent component,
  ) async {
    StorageCodec.encodeBinding(binding);
    final root = await _root(binding.location);
    final id = binding.key.dumpId;
    if (binding.metadataName != '$id.meta.json' ||
        binding.audio.kind != 'file' ||
        !p.equals(p.dirname(binding.audio.value), root) ||
        p.basename(binding.audio.value) != '$id.opus') {
      _invalid('Binding does not identify exact owned components');
    }
    return p.join(
      root,
      component == RecordingComponent.audio ? '$id.opus' : binding.metadataName,
    );
  }

  Future<void> _regular(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      _invalid('Expected an owned regular file');
    }
  }

  Future<ComponentResult> _remove(String path) async {
    try {
      final name = p.basename(path);
      final entries =
          await Directory(p.dirname(path)).list(followLinks: false).toList();
      final listed = entries.any(
        (e) =>
            p.basename(e.path) == name ||
            (Platform.isWindows &&
                p.basename(e.path).toLowerCase() == name.toLowerCase()),
      );
      if (!listed) return (state: ComponentState.absent, problem: null);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return (
          state: ComponentState.unknown,
          problem: (
            code: ProblemCode.unknown,
            message: 'Listed component could not be inspected'
          )
        );
      }
      if (type != FileSystemEntityType.file) {
        return (
          state: ComponentState.failed,
          problem: (
            code: ProblemCode.invalid,
            message: 'Not an owned regular file'
          )
        );
      }
      await File(path).delete();
      return (state: ComponentState.removed, problem: null);
    } on FileSystemException catch (e) {
      return (
        state: ComponentState.failed,
        problem: (code: ProblemCode.io, message: e.message)
      );
    }
  }

  @override
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding) => _run(
        () => _outcome(() async {
          final path = await _component(binding, RecordingComponent.audio);
          await _regular(path);
          return File(path).readAsBytes();
        }),
      );
  @override
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding) =>
      _run(
        () => _outcome(() async {
          await _regular(await _component(binding, RecordingComponent.audio));
          return binding.audio;
        }),
      );
  @override
  IoOperation<ComponentResult> deleteComponent(
    BoundRecording binding,
    RecordingComponent component,
    String operationId,
  ) =>
      _run(() async {
        try {
          StorageCodec.validateLiteralId(operationId);
          return await _remove(await _component(binding, component));
        } on StorageFault catch (e) {
          return (state: ComponentState.failed, problem: e.problem);
        } on FileSystemException catch (e) {
          return (
            state: ComponentState.failed,
            problem: (code: ProblemCode.io, message: e.message)
          );
        }
      });
  @override
  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  @override
  Future<List<RestoredUse>> unsettledUses() async => [];
  @override
  Future<Outcome<StorageLocation?>> pickDirectory() async => const Fail(
        (
          code: ProblemCode.unsupported,
          message: 'Folder selection is Android-only'
        ),
      );
  @override
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({
    required String filesystemLegacyDirectory,
    String? frozenAnchorJson,
  }) =>
      _run(
        () => _outcome<LegacyStorage?>(() async {
          if (frozenAnchorJson == null) {
            return (
              location: null,
              anchorJson:
                  StorageCodec.encodeLegacyFileAnchor(filesystemLegacyDirectory)
            );
          }
          final envelope = StorageCodec.decodeLegacyAnchor(
            frozenAnchorJson,
            expectedKind: 'legacy-file-root',
          );
          final path = envelope['path'] as String;
          final location = (
            id: 'legacy-filesystem',
            label: path,
            directory: (
              kind: 'file',
              path: path,
              treeUri: '',
              authority: '',
              documentId: ''
            )
          );
          try {
            await Directory(await _root(location))
                .list(followLinks: false)
                .toList();
            return (location: location, anchorJson: frozenAnchorJson);
          } on StorageFault {
            return (location: null, anchorJson: frozenAnchorJson);
          } on FileSystemException {
            return (location: null, anchorJson: frozenAnchorJson);
          }
        }),
      ).result;
  @override
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location) => _run(
        () => _outcome(() async {
          await Directory(await _root(location))
              .list(followLinks: false)
              .toList();
        }),
      );
  Future<File> _temporary(String root, String prefix) async {
    StorageCodec.validateLiteralId(prefix);
    final file = File(
      p.join(
        root,
        '.$prefix-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}.partial',
      ),
    );
    await file.create(exclusive: true);
    return file;
  }

  void _metadata(RecordingKey key, Map<String, dynamic> metadata) {
    StorageCodec.encodeKey(key);
    if (metadata['id'] != key.dumpId || metadata['schemaVersion'] != 2) {
      _invalid('Metadata identity/schema mismatch');
    }
  }

  @override
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  ) =>
      _run(
        () => _outcome(() async {
          StorageCodec.validateLiteralId(operationId);
          _metadata(binding.key, metadata);
          final path = await _component(binding, RecordingComponent.metadata);
          final type = await FileSystemEntity.type(path, followLinks: false);
          if (type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound) {
            _invalid('Not an owned metadata file');
          }
          final tmp = await _temporary(p.dirname(path), operationId);
          try {
            await tmp.writeAsString(jsonEncode(metadata), flush: true);
            await tmp.rename(path);
          } finally {
            if (await tmp.exists()) await tmp.delete();
          }
        }),
      );
  @override
  IoOperation<Outcome<PublishedCapture>> publishCapture(
    CaptureReservation reservation,
    Map<String, dynamic> metadata,
  ) =>
      _run(
        () => _outcome(() async {
          StorageCodec.validateLiteralId(reservation.id);
          _metadata(reservation.key, metadata);
          final root = await _root(reservation.location);
          final id = reservation.key.dumpId;
          final audio = File(p.join(root, '$id.opus'));
          final meta = File(p.join(root, '$id.meta.json'));
          await _regular(reservation.stagingPath);
          final bytes = await File(reservation.stagingPath).readAsBytes();
          if (bytes.isEmpty) _invalid('Empty staging audio');
          for (final target in [audio, meta]) {
            if (await FileSystemEntity.type(
                  target.path,
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound) {
              throw const StorageFault(
                (
                  code: ProblemCode.conflict,
                  message: 'Capture target already exists'
                ),
              );
            }
          }
          // Exclusive target claims prevent replacing another capture. Staging is
          // never removed; higher-level reservation recovery owns partial publication.
          await audio.create(exclusive: true);
          try {
            await meta.create(exclusive: true);
          } on FileSystemException {
            await audio.delete();
            rethrow;
          }
          final tmp = await _temporary(root, reservation.id);
          try {
            await tmp.writeAsBytes(bytes, flush: true);
            await tmp.rename(audio.path);
            final metadataTemp = await _temporary(root, reservation.id);
            try {
              await metadataTemp.writeAsString(
                jsonEncode(metadata),
                flush: true,
              );
              await metadataTemp.rename(meta.path);
            } finally {
              if (await metadataTemp.exists()) await metadataTemp.delete();
            }
          } finally {
            if (await tmp.exists()) await tmp.delete();
          }
          return (
            binding: (
              key: reservation.key,
              location: reservation.location,
              audio: (kind: 'file', value: audio.path),
              metadataName: '$id.meta.json'
            ),
            sizeBytes: bytes.length
          );
        }),
      );
  @override
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(
    String token,
    StorageLocation location,
  ) =>
      _run(
        () => _outcome(() async {
          StorageCodec.validateLiteralId(token);
          final root = await _root(location);
          final original = await _temporary(root, token);
          final renamed = '${original.path}.renamed';
          final owned = <AudioLocator>[(kind: 'file', value: original.path)];
          File current = original;
          try {
            await original.writeAsString('tangent-probe', flush: true);
            if (await original.readAsString() != 'tangent-probe') {
              _invalid('Probe readback mismatch');
            }
            current = await original.rename(renamed);
            owned.add((kind: 'file', value: renamed));
            final result = await _remove(current.path);
            return (
              owned: owned,
              cleaned: result.state == ComponentState.removed ||
                  result.state == ComponentState.absent
            );
          } catch (_) {
            final cleanup = await _remove(current.path);
            if (cleanup.state != ComponentState.removed &&
                cleanup.state != ComponentState.absent) {
              return (owned: owned, cleaned: false);
            }
            rethrow;
          }
        }),
      );
  @override
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(
    StorageLocation location,
  ) =>
      _run(
        () => _outcome(() async {
          final root = await _root(location);
          final result = <ImportedEntry>[];
          final entries =
              await Directory(root).list(followLinks: false).toList();
          for (final entry in entries) {
            if (!entry.path.endsWith('.opus')) continue;
            final id = p.basenameWithoutExtension(entry.path);
            Map<String, dynamic>? metadata;
            StorageProblem? problem;
            var size = 0;
            var modified = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            try {
              StorageCodec.validateLiteralId(id);
              await _regular(entry.path);
              final stat = await entry.stat();
              size = stat.size;
              modified = stat.modified;
              final meta = File(p.join(root, '$id.meta.json'));
              if (entries.any((e) => p.equals(e.path, meta.path))) {
                await _regular(meta.path);
                final decoded = jsonDecode(await meta.readAsString());
                if (decoded is! Map<String, dynamic> ||
                    decoded['id'] != id ||
                    decoded['schemaVersion'] != 2) {
                  _invalid('Metadata identity/schema mismatch');
                }
                metadata = decoded;
              }
            } on StorageFault catch (e) {
              problem = e.problem;
            } on FileSystemException catch (e) {
              problem = (code: ProblemCode.io, message: e.message);
            } on FormatException {
              problem =
                  (code: ProblemCode.invalid, message: 'Malformed metadata');
            }
            result.add(
              (
                id: id,
                source: location,
                audio: (kind: 'file', value: entry.path),
                sizeBytes: size,
                modifiedAt: modified,
                metadata: metadata,
                problem: problem
              ),
            );
          }
          return result;
        }),
      );
}

class _FileOperation<T> implements IoOperation<T> {
  _FileOperation(this.id, Future<T> Function() action) {
    result = Future<T>(() async {
      try {
        return await action();
      } finally {
        _settled.complete();
      }
    });
  }
  @override
  final String id;
  @override
  late final Future<T> result;
  final _settled = Completer<void>();
  @override
  Future<void> get settled => _settled.future;
}

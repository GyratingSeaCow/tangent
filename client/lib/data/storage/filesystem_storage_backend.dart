// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../../services/audio_gain.dart' show amplifiedContentExtension;
import 'storage_codec.dart';
import 'storage_contract.dart';
import 'capture_publication_codec.dart';
import 'filesystem_capture_io.dart';

/// Explicit-root operations. The caller owns admission/publication leases.
class FilesystemStorageBackend implements StorageBackend {
  // Process-owned optimization only. SQLite, never this map, owns recovery.
  static final _preparations = <String,
      ({
    String payload,
    RecordingKey key,
    _FileOperation<CapturePreparationResult> operation
  })>{};
  static final _acknowledgedPreparations = <String, String>{};
  static final _captureWork = <String, RestoredUse>{};

  @override
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation r,
    String metadataJson,
    String audioSha256,
    String operationId, {
    required bool observeOnly,
  }) {
    CapturePreparationResult failure(ProblemCode code, String message) => (
          state: observeOnly
              ? CapturePreparationState.uncertain
              : CapturePreparationState.notStarted,
          preparation: null,
          rawReturnedLocators: <String>[],
          problem: (code: code, message: message)
        );
    late String payload;
    try {
      CapturePublicationCodec.operationId(r, operationId);
      CapturePublicationCodec.digest(audioSha256);
      payload = jsonEncode([
        CapturePublicationCodec.reservationMap(r),
        metadataJson,
        audioSha256,
      ]);
    } on StorageFault catch (e) {
      return _FileOperation(
        operationId,
        () async => failure(e.problem.code, e.problem.message),
      );
    }
    final retained = _preparations[operationId];
    if (retained != null) {
      if (retained.payload != payload) {
        return _FileOperation(
          operationId,
          () async => failure(
            ProblemCode.conflict,
            'Preparation ID has another payload',
          ),
        );
      }
      return retained.operation;
    }
    final acknowledged = _acknowledgedPreparations[operationId];
    if (observeOnly || acknowledged != null) {
      return _FileOperation(
        operationId,
        () async => (
          state: CapturePreparationState.uncertain,
          preparation: null,
          rawReturnedLocators: <String>[],
          problem: (
            code: acknowledged != null && acknowledged != payload
                ? ProblemCode.conflict
                : ProblemCode.unresolved,
            message: 'Preparation result is not retained'
          )
        ),
      );
    }
    final operation = _FileOperation(
      operationId,
      () async => FilesystemCaptureIo.prepare(r, metadataJson, audioSha256),
    );
    _preparations[operationId] =
        (payload: payload, key: r.key, operation: operation);
    _pending.add(operation.settled);
    unawaited(
      operation.settled.then((_) => _pending.remove(operation.settled)),
    );
    return operation;
  }

  @override
  Future<Outcome<void>> acknowledgeCapturePreparation(
    String operationId,
  ) async {
    try {
      StorageCodec.validateLiteralId(operationId);
    } on StorageFault catch (e) {
      return Fail(e.problem);
    }
    final retained = _preparations[operationId];
    if (retained == null) {
      return _acknowledgedPreparations.containsKey(operationId)
          ? const Ok(null)
          : const Fail(
              (
                code: ProblemCode.unresolved,
                message: 'Preparation is not retained'
              ),
            );
    }
    if (!retained.operation._settled.isCompleted) {
      return const Fail(
        (code: ProblemCode.busy, message: 'Preparation has not settled'),
      );
    }
    _acknowledgedPreparations[operationId] = retained.payload;
    _preparations.remove(operationId);
    return const Ok(null);
  }

  IoOperation<Outcome<T>> _captureOperation<T>(
    CaptureReservation r,
    Outcome<T> Function() action,
  ) {
    final op = _run(() async => action());
    _captureWork[op.id] =
        (key: r.key, kind: UseKind.capture, settled: op.settled);
    unawaited(op.settled.then((_) => _captureWork.remove(op.id)));
    return op;
  }

  @override
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) =>
      _captureOperation(r, () => FilesystemCaptureIo.inspect(r, preparation));
  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) =>
      _captureOperation(r, () => FilesystemCaptureIo.publish(r, preparation));

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
    // A binding carries neither mode nor gain, so every name a capture may
    // legitimately hold is acceptable here. Amplified audio is PCM in a WAV
    // container, so '.wav' belongs alongside the mode-derived names — omitting
    // it made an amplified recording unrecognisable as its own content.
    final contentNames = {
      for (final mode in const ['brain_dump', 'meeting', 'text_note'])
        '$id.${contentExtensionForMode(mode)}',
      '$id.$amplifiedContentExtension',
    };
    // The binding locator is authoritative for the parent: audio modes (and
    // legacy notes) live at the root, published text notes live inside the
    // owned 'Tangent Text Notes' child, and downloaded synced audio lives
    // inside 'Tangent Synced Audio'. Only the matching content name may bind
    // through each subdirectory.
    final parent = p.dirname(binding.audio.value);
    final basename = p.basename(binding.audio.value);
    final rootParent = p.equals(parent, root);
    final noteParent =
        p.equals(parent, p.join(root, textNoteSubdirectoryName)) &&
            basename == '$id.${contentExtensionForMode('text_note')}';
    // Synced audio is always audio, never a note: only audio content names
    // may resolve through this child, so a markdown file smuggled into the
    // downloads folder still faults.
    final syncedParent =
        p.equals(parent, p.join(root, syncedAudioSubdirectoryName)) &&
            (basename == '$id.opus' || basename == '$id.wav');
    if (binding.metadataName != '$id.meta.json' ||
        binding.audio.kind != 'file' ||
        (!rootParent && !noteParent && !syncedParent) ||
        !contentNames.contains(basename)) {
      _invalid('Binding does not identify exact owned components');
    }
    // The sidecar always lives beside its content component.
    return p.join(
      parent,
      component == RecordingComponent.audio ? basename : binding.metadataName,
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
  Future<List<RestoredUse>> unsettledUses() async => [
        ..._preparations.values.map(
          (entry) => (
            key: entry.key,
            kind: UseKind.capture,
            settled: entry.operation.settled
          ),
        ),
        ..._captureWork.values,
      ];
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
          // Reachability only — existence and directory-ness. Listing the whole
          // folder here made every record tap pay for a full enumeration.
          final root = Directory(await _root(location));
          if (!await root.exists()) {
            throw const StorageFault(
              (code: ProblemCode.absent, message: 'Recording folder is unavailable'),
            );
          }
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
  /// Not specialised here: a local directory listing is a single cheap
  /// syscall, unlike SAF where every child costs a provider round trip.
  /// Returning null keeps this backend on the shared listing path, so its
  /// behaviour is byte-for-byte what it was before [readRecordingAt] existed.
  @override
  IoOperation<Outcome<ImportedEntry?>>? readRecordingAt(
    StorageLocation location,
    String dumpId,
  ) =>
      null;

  @override
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(
    StorageLocation location,
  ) =>
      _run(
        () => _outcome(() async {
          final root = await _root(location);
          final result = <ImportedEntry>[];
          // Owned primary-content names derive from the ONE shared mode
          // helper (see _component): audio modes publish .opus, text notes
          // publish .md. Both are enumerable durable-pair content. Text
          // notes publish inside the 'Tangent Text Notes' child; legacy
          // root-level .md pairs still import (tolerance, no migration).
          final contentSuffixes = {
            for (final mode in const ['brain_dump', 'meeting', 'text_note'])
              '.${contentExtensionForMode(mode)}',
            '.$amplifiedContentExtension',
          };
          Future<void> scan(String directory) async {
            final entries =
                await Directory(directory).list(followLinks: false).toList();
            for (final entry in entries) {
              if (!contentSuffixes.any(entry.path.endsWith)) continue;
              final id = p.basenameWithoutExtension(entry.path);
              Map<String, dynamic>? metadata;
              StorageProblem? problem;
              var size = 0;
              var modified =
                  DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
              try {
                StorageCodec.validateLiteralId(id);
                await _regular(entry.path);
                final stat = await entry.stat();
                size = stat.size;
                modified = stat.modified;
                final meta = File(p.join(directory, '$id.meta.json'));
                if (entries.any((e) => p.equals(e.path, meta.path))) {
                  await _regular(meta.path);
                  final decoded = jsonDecode(await meta.readAsString());
                  if (decoded is! Map<String, dynamic> ||
                      decoded['id'] != id ||
                      !const [1, 2].contains(decoded['schemaVersion'])) {
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
          }

          await scan(root);
          final noteDirectory = p.join(root, textNoteSubdirectoryName);
          if (await FileSystemEntity.type(noteDirectory, followLinks: false) ==
              FileSystemEntityType.directory) {
            await scan(noteDirectory);
          }
          return result;
        }),
      );

  /// Resolves the named child of an owned root. Idempotent: an existing real
  /// directory is reused, a same-name non-directory is a conflict (never a
  /// silent fall back to the root, which would scatter documents), and the
  /// child is only created when [create] is set.
  Future<String?> _childDirectory(
    StorageLocation location,
    String directoryName, {
    required bool create,
  }) async {
    StorageCodec.validateLiteralId(directoryName);
    final root = await _root(location);
    final child = p.join(root, directoryName);
    final type = await FileSystemEntity.type(child, followLinks: false);
    if (type == FileSystemEntityType.directory) return child;
    if (type != FileSystemEntityType.notFound) {
      throw const StorageFault(
        (
          code: ProblemCode.conflict,
          message: 'Document directory name is not a directory'
        ),
      );
    }
    if (!create) return null;
    await Directory(child).create();
    if (await FileSystemEntity.type(child, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const StorageFault(
        (
          code: ProblemCode.unavailable,
          message: 'Created document directory is not observable'
        ),
      );
    }
    return child;
  }

  @override
  IoOperation<Outcome<DurableDocument>> publishDocument(
    StorageLocation location,
    String directoryName,
    String name,
    String content,
    String publicationId,
  ) =>
      _run(
        () => _outcome(() async {
          StorageCodec.validateLiteralId(publicationId);
          StorageCodec.validateLiteralId(name);
          final directory = (await _childDirectory(
            location,
            directoryName,
            create: true,
          ))!;
          final target = p.join(directory, name);
          final type = await FileSystemEntity.type(target, followLinks: false);
          if (type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound) {
            _invalid('Not an owned document file');
          }
          // Write-then-rename: a torn write never replaces the last good copy.
          final tmp = await _temporary(directory, publicationId);
          try {
            await tmp.writeAsString(content, flush: true);
            await tmp.rename(target);
          } finally {
            if (await tmp.exists()) await tmp.delete();
          }
          return (
            name: name,
            locator: (kind: 'file', value: target),
            content: content
          );
        }),
      );

  @override
  IoOperation<Outcome<DurableDocument>> publishBinaryDocument(
    StorageLocation location,
    String directoryName,
    String name,
    List<int> bytes,
    String mimeType,
    String publicationId,
  ) =>
      _run(
        () => _outcome(() async {
          StorageCodec.validateLiteralId(publicationId);
          StorageCodec.validateLiteralId(name);
          if (bytes.isEmpty) _invalid('Refusing to publish an empty document');
          final directory = (await _childDirectory(
            location,
            directoryName,
            create: true,
          ))!;
          final target = p.join(directory, name);
          final type = await FileSystemEntity.type(target, followLinks: false);
          if (type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound) {
            _invalid('Not an owned document file');
          }
          // Write-then-rename: a torn write never replaces the last good copy.
          final tmp = await _temporary(directory, publicationId);
          try {
            await tmp.writeAsBytes(bytes, flush: true);
            // Verify before replacing. A short write is silent otherwise, and
            // the failure would not surface until playback.
            final int written = await tmp.length();
            if (written != bytes.length) {
              _invalid('Document readback mismatch');
            }
            await tmp.rename(target);
          } finally {
            if (await tmp.exists()) await tmp.delete();
          }
          // `content` describes TEXT documents; binary publication reports an
          // empty string rather than decoding audio into one.
          return (
            name: name,
            locator: (kind: 'file', value: target),
            content: ''
          );
        }),
      );

  @override
  IoOperation<Outcome<List<DurableDocument>>> listDocuments(
    StorageLocation location,
    String directoryName,
    String suffix,
  ) =>
      _run(
        () => _outcome(() async {
          final directory =
              await _childDirectory(location, directoryName, create: false);
          if (directory == null) return <DurableDocument>[];
          final result = <DurableDocument>[];
          final entries =
              await Directory(directory).list(followLinks: false).toList();
          for (final entry in entries) {
            final name = p.basename(entry.path);
            if (!name.endsWith(suffix) || name.length == suffix.length) {
              continue;
            }
            await _regular(entry.path);
            result.add(
              (
                name: name,
                locator: (kind: 'file', value: entry.path),
                content: await File(entry.path).readAsString()
              ),
            );
          }
          return result;
        }),
      );

  @override
  IoOperation<ComponentResult> deleteDocument(
    StorageLocation location,
    String directoryName,
    String name,
    AudioLocator locator,
    String operationId,
  ) =>
      _run(() async {
        try {
          StorageCodec.validateLiteralId(operationId);
          StorageCodec.validateLiteralId(name);
          StorageCodec.encodeAudio(locator);
          final directory =
              await _childDirectory(location, directoryName, create: false);
          if (directory == null) {
            return (state: ComponentState.absent, problem: null);
          }
          // The stored locator is authoritative for identity, but it must
          // still resolve inside the owned child under the expected name:
          // a foreign locator is refused rather than followed.
          if (locator.kind != 'file' ||
              !p.equals(p.dirname(locator.value), directory) ||
              p.basename(locator.value) != name) {
            _invalid('Locator does not identify an owned document');
          }
          return await _remove(locator.value);
        } on StorageFault catch (e) {
          return (state: ComponentState.failed, problem: e.problem);
        } on FileSystemException catch (e) {
          return (
            state: ComponentState.failed,
            problem: (code: ProblemCode.io, message: e.message)
          );
        }
      });
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

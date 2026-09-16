// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'capture_publication_codec.dart';
import 'storage_contract.dart';
import 'filesystem_capture_io_windows.dart';
import 'filesystem_capture_io_posix.dart';

/// Handle-bound primitives for initial capture only. No rename/unlink/truncate.
abstract class CaptureFileHandle {
  String get path;
  bool get isDirectory;
  CaptureObjectIdentity get identity;
  int get size;
  Uint8List readBytes();
  void initialize(CaptureObjectIdentity expected, Uint8List bytes);
  CaptureFileHandle openChild(
    String name, {
    bool create = false,
    bool writable = false,
    void Function(String)? onCreated,
  });
  void close();

  void verifyAssociation() {
    final current = openCaptureHandle(path, directory: isDirectory);
    try {
      if (current.identity != identity) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture path association changed',
        );
      }
    } finally {
      current.close();
    }
  }
}

Never captureIoFault(ProblemCode code, String message) =>
    throw StorageFault((code: code, message: message));

CaptureFileHandle openCaptureHandle(
  String path, {
  bool directory = false,
  bool writable = false,
  bool create = false,
}) {
  if (Platform.isWindows) {
    return WindowsCaptureHandle.open(
      path,
      directory: directory,
      writable: writable,
      create: create,
    );
  }
  if (Platform.isLinux) {
    return PosixCaptureHandle.open(
      path,
      directory: directory,
      writable: writable,
      create: create,
    );
  }
  captureIoFault(
    ProblemCode.unsupported,
    'Capture object identity is unsupported on this OS',
  );
}

/// New initial-capture policy. The service must persist/re-read both claims
/// before calling publish. This layer never infers that SQL authorization.
abstract final class FilesystemCaptureIo {
  static bool equalBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static void _inputs(CaptureReservation r, String metadata, String digest) {
    CapturePublicationCodec.reservationMap(r);
    CapturePublicationCodec.digest(digest);
    if (r.location.directory.kind != 'file' ||
        p.basename(r.stagingPath) != '${r.id}.opus' ||
        CapturePublicationCodec.metadata(metadata, r.key.dumpId)['mode'] !=
            r.mode) {
      captureIoFault(
        ProblemCode.invalid,
        'Incoherent filesystem capture input',
      );
    }
  }

  static void _available(CaptureFileHandle root, Set<String> names) {
    root.verifyAssociation();
    final entries = Directory(root.path).listSync(followLinks: false);
    for (final entry in entries) {
      final actual = p.basename(entry.path);
      if (names.any(
        (name) => Platform.isWindows
            ? name.toLowerCase() == actual.toLowerCase()
            : name == actual,
      )) {
        captureIoFault(ProblemCode.conflict, 'Capture target already exists');
      }
    }
    root.verifyAssociation();
  }

  static CapturePreparationResult prepare(
    CaptureReservation r,
    String metadata,
    String digest,
  ) {
    CaptureFileHandle? root;
    CaptureFileHandle? source;
    CaptureComponentClaim? audio;
    CaptureComponentClaim? meta;
    PreparedCapture? preparation;
    final raw = <String>[];
    var dispatched = false;
    void snapshot() {
      preparation = (
        publicationId: r.id,
        reservationId: r.id,
        key: r.key,
        location: r.location,
        stagingPath: r.stagingPath,
        sourceIdentity: source!.identity,
        rootIdentity: root!.identity,
        audioSizeBytes: source.size,
        audioSha256: digest,
        metadataJson: metadata,
        audio: audio,
        metadata: meta
      );
    }

    try {
      _inputs(r, metadata, digest);
      source = openCaptureHandle(r.stagingPath);
      final bytes = source.readBytes();
      if (bytes.isEmpty || sha256.convert(bytes).toString() != digest) {
        captureIoFault(ProblemCode.conflict, 'Frozen staging bytes changed');
      }
      root = openCaptureHandle(r.location.directory.path, directory: true);
      source.verifyAssociation();
      _available(root, {'${r.key.dumpId}.opus', '${r.key.dumpId}.meta.json'});
      final sourceIdentity = source.identity;
      final rootIdentity = root.identity;
      snapshot();
      for (final component in RecordingComponent.values) {
        final name = component == RecordingComponent.audio
            ? '${r.key.dumpId}.opus'
            : '${r.key.dumpId}.meta.json';
        _available(root, {name});
        dispatched = true;
        final target = root.openChild(
          name,
          create: true,
          writable: true,
          onCreated: raw.add,
        );
        try {
          final claim = (
            component: component,
            name: name,
            locator: (kind: 'file', value: target.path),
            identity: target.identity
          );
          if (component == RecordingComponent.audio) {
            audio = claim;
          } else {
            meta = claim;
          }
          snapshot();
          if (target.size != 0) {
            captureIoFault(
              ProblemCode.conflict,
              'Created capture target is not empty',
            );
          }
          target.verifyAssociation();
        } finally {
          target.close();
        }
      }
      if (source.identity != sourceIdentity ||
          root.identity != rootIdentity ||
          !equalBytes(source.readBytes(), bytes)) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture source or root changed during preparation',
        );
      }
      source.verifyAssociation();
      root.verifyAssociation();
      final result = (
        state: CapturePreparationState.prepared,
        preparation: preparation,
        rawReturnedLocators: raw,
        problem: null as StorageProblem?
      );
      CapturePublicationCodec.encodeResult(result);
      return result;
    } catch (e) {
      final problem = _problem(e);
      return (
        state: dispatched
            ? CapturePreparationState.uncertain
            : CapturePreparationState.notStarted,
        preparation: dispatched ? preparation : null,
        rawReturnedLocators: raw,
        problem: problem
      );
    } finally {
      source?.close();
      root?.close();
    }
  }

  static StorageProblem _problem(Object e) => switch (e) {
        StorageFault(:final problem) => problem,
        FileSystemException() => (
            code: ProblemCode.io,
            message: 'Capture filesystem observation failed'
          ),
        ArgumentError() => (
            code: ProblemCode.unsupported,
            message: 'Capture native identity ABI unavailable'
          ),
        _ => throw e,
      };
  static T _proof<T>(
    CaptureReservation r,
    PreparedCapture prep,
    T Function(CaptureFileHandle root, Uint8List audio, Uint8List metadata)
        action,
  ) {
    CapturePublicationCodec.validateReservation(r, prep);
    _inputs(r, prep.metadataJson, prep.audioSha256);
    if (prep.audio == null || prep.metadata == null) {
      captureIoFault(
        ProblemCode.unresolved,
        'Capture preparation is incomplete',
      );
    }
    final source = openCaptureHandle(r.stagingPath);
    CaptureFileHandle? root;
    try {
      root = openCaptureHandle(r.location.directory.path, directory: true);
      if (source.identity != prep.sourceIdentity ||
          root.identity != prep.rootIdentity) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture source/root identity changed',
        );
      }
      final bytes = source.readBytes();
      if (bytes.length != prep.audioSizeBytes ||
          sha256.convert(bytes).toString() != prep.audioSha256) {
        captureIoFault(ProblemCode.conflict, 'Frozen staging content changed');
      }
      source.verifyAssociation();
      root.verifyAssociation();
      final result = action(
        root,
        bytes,
        Uint8List.fromList(utf8.encode(prep.metadataJson)),
      );
      source.verifyAssociation();
      root.verifyAssociation();
      if (source.identity != prep.sourceIdentity ||
          root.identity != prep.rootIdentity ||
          !equalBytes(source.readBytes(), bytes)) {
        captureIoFault(
          ProblemCode.conflict,
          'Capture proof changed during operation',
        );
      }
      return result;
    } finally {
      source.close();
      root?.close();
    }
  }

  static CaptureFileHandle _target(
    CaptureFileHandle root,
    CaptureComponentClaim claim, {
    bool writable = false,
  }) {
    if (claim.locator.value != p.join(root.path, claim.name)) {
      captureIoFault(
        ProblemCode.conflict,
        'Capture claim is outside reserved root',
      );
    }
    final handle = root.openChild(claim.name, writable: writable);
    try {
      if (handle.identity != claim.identity) {
        captureIoFault(ProblemCode.conflict, 'Capture target was replaced');
      }
      handle.verifyAssociation();
      return handle;
    } catch (_) {
      handle.close();
      rethrow;
    }
  }

  static CaptureContentState _state(Uint8List actual, Uint8List expected) =>
      actual.isEmpty
          ? CaptureContentState.empty
          : equalBytes(actual, expected)
              ? CaptureContentState.complete
              : CaptureContentState.partial;
  static CaptureComponentInspection _inspect(
    CaptureFileHandle root,
    CaptureComponentClaim claim,
    Uint8List expected,
  ) {
    CaptureFileHandle? handle;
    try {
      handle = _target(root, claim);
      final state = _state(handle.readBytes(), expected);
      handle.verifyAssociation();
      return (
        state: state,
        problem: state == CaptureContentState.partial
            ? (
                code: ProblemCode.unresolved,
                message: 'Nonempty capture component differs'
              )
            : null
      );
    } catch (e) {
      final problem = _problem(e);
      return (
        state: switch (problem.code) {
          ProblemCode.absent => CaptureContentState.absent,
          ProblemCode.conflict ||
          ProblemCode.invalid =>
            CaptureContentState.foreign,
          _ => CaptureContentState.unknown,
        },
        problem: problem
      );
    } finally {
      handle?.close();
    }
  }

  static Outcome<CaptureInspection> inspect(
    CaptureReservation r,
    PreparedCapture prep,
  ) {
    try {
      return Ok(
        _proof(
          r,
          prep,
          (root, audio, metadata) => (
            audio: _inspect(root, prep.audio!, audio),
            metadata: _inspect(root, prep.metadata!, metadata)
          ),
        ),
      );
    } catch (e) {
      return Fail(_problem(e));
    }
  }

  static Outcome<PublishedCapture> publish(
    CaptureReservation r,
    PreparedCapture prep,
  ) {
    try {
      final initial = inspect(r, prep);
      if (initial case Fail(:final problem)) return Fail(problem);
      final before = (initial as Ok<CaptureInspection>).value;
      for (final component in [before.audio, before.metadata]) {
        if (component.state != CaptureContentState.empty &&
            component.state != CaptureContentState.complete) {
          captureIoFault(
            ProblemCode.unresolved,
            'Capture pair is not safe to initialize',
          );
        }
      }
      _proof(r, prep, (root, audioBytes, metaBytes) {
        // Open and validate BOTH before the first write, not one at a time.
        final audio = _target(
          root,
          prep.audio!,
          writable: before.audio.state == CaptureContentState.empty,
        );
        CaptureFileHandle? meta;
        try {
          meta = _target(
            root,
            prep.metadata!,
            writable: before.metadata.state == CaptureContentState.empty,
          );
          final a = _state(audio.readBytes(), audioBytes);
          final m = _state(meta.readBytes(), metaBytes);
          if (a == CaptureContentState.partial ||
              m == CaptureContentState.partial) {
            captureIoFault(
              ProblemCode.unresolved,
              'Partial capture content cannot be overwritten',
            );
          }
          if (a == CaptureContentState.empty) {
            audio.initialize(prep.audio!.identity, audioBytes);
          }
          if (!equalBytes(audio.readBytes(), audioBytes)) {
            captureIoFault(ProblemCode.io, 'Capture audio readback failed');
          }
          if (m == CaptureContentState.empty) {
            meta.initialize(prep.metadata!.identity, metaBytes);
          }
          if (!equalBytes(meta.readBytes(), metaBytes)) {
            captureIoFault(ProblemCode.io, 'Capture metadata readback failed');
          }
          audio.verifyAssociation();
          meta.verifyAssociation();
        } finally {
          audio.close();
          meta?.close();
        }
      });
      final verified = inspect(r, prep);
      if (verified case Fail(:final problem)) return Fail(problem);
      final inspection = (verified as Ok<CaptureInspection>).value;
      if (inspection.audio.state != CaptureContentState.complete ||
          inspection.metadata.state != CaptureContentState.complete) {
        captureIoFault(ProblemCode.unresolved, 'Capture pair is not complete');
      }
      return Ok(
        (
          binding: (
            key: r.key,
            location: r.location,
            audio: prep.audio!.locator,
            metadataName: prep.metadata!.name
          ),
          sizeBytes: prep.audioSizeBytes
        ),
      );
    } catch (e) {
      return Fail(_problem(e));
    }
  }
}

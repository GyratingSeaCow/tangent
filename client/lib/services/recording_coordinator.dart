// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart' show SqliteException;
import 'package:flutter/services.dart';
import '../data/local_db.dart';
import '../data/storage/storage_contract.dart';
import 'recording_service.dart';
import 'recording_persistence.dart';

class DefaultRecordingCoordinator implements RecordingCoordinator {
  DefaultRecordingCoordinator({
    required LocalDb db,
    required StorageCatalog catalog,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
    required RecordingService recorder,
    required DateTime Function() now,
  })  : _db = db,
        _catalog = catalog,
        _mutations = mutations,
        _recorder = recorder,
        _now = now,
        _persistence = RecordingPersistence(
          db: db,
          backend: backend,
          mutations: mutations,
        );
  final LocalDb _db;
  final StorageCatalog _catalog;
  final RecordingMutationCoordinator _mutations;
  final RecordingService _recorder;
  final DateTime Function() _now;
  final RecordingPersistence _persistence;
  final _changes = StreamController<RecordingLifecycleState>.broadcast();
  RecordingLifecycleState _state =
      (phase: CapturePhase.idle, reservation: null, problem: null);
  CaptureReservation? _active;
  UseLease? _lease;
  bool _busy = false;
  T _value<T>(Outcome<T> result) => switch (result) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem)
      };
  void _emit(CapturePhase phase, {StorageProblem? problem}) {
    final r = _active;
    _state = (
      phase: phase,
      reservation: r == null
          ? null
          : (
              id: r.id,
              key: r.key,
              location: r.location,
              stagingPath: r.stagingPath,
              mode: r.mode,
              startedAt: r.startedAt,
              phase: phase
            ),
      problem: problem
    );
    _changes.add(_state);
  }

  @override
  Stream<RecordingLifecycleState> watchState() => Stream.multi((sink) {
        final subscription =
            _changes.stream.listen(sink.add, onError: sink.addError);
        sink.add(_state);
        sink.onCancel = subscription.cancel;
      });
  StorageProblem _problem(Object error) => switch (error) {
        StorageFault(:final problem) => problem,
        SqliteException() => (
            code: ProblemCode.persistence,
            message: 'Capture persistence failed'
          ),
        _ => (code: ProblemCode.io, message: 'Recorder or publication failed'),
      };
  Future<void> _failed(StorageProblem problem) async {
    final r = _active;
    if (r != null) {
      var phase = CapturePhase.failed;
      try {
        await _persistence.markState(r, CapturePhase.failed);
        final row = await (_db.select(_db.captureReservations)
              ..where((s) => s.reservationId.equals(r.id)))
            .getSingleOrNull();
        if (row?.state == 'committed') phase = CapturePhase.committed;
      } on SqliteException {
        /* Durable reservation/staging remain for recovery. */
      } on StorageFault {
        /* An obsolete owner cannot write the replacement journal. */
      }
      _emit(phase, problem: problem);
    } else {
      _emit(CapturePhase.failed, problem: problem);
    }
  }

  @override
  Future<Outcome<CaptureReservation>> start({required String mode}) async {
    if (_busy || _active != null) {
      return const Fail(
        (code: ProblemCode.busy, message: 'Recording is active'),
      );
    }
    _busy = true;
    try {
      final r = _value(await _catalog.reserveCapture(mode: mode));
      _active = r;
      _emit(CapturePhase.reserved);
      _lease = _value(
        await _mutations.catalogAdmission(
          () => _mutations.acquire(
            r.key.dumpId,
            UseKind.capture,
            expectedIncarnation: r.key.incarnation,
          ),
        ),
      );
      final path = await _recorder.start(stagingPath: r.stagingPath);
      if (path != r.stagingPath) {
        throw const StorageFault(
          (
            code: ProblemCode.invalid,
            message: 'Recorder start path differs from reservation'
          ),
        );
      }
      await _persistence.markState(r, CapturePhase.recording);
      _emit(CapturePhase.recording);
      return Ok(_state.reservation!);
    } catch (error) {
      if (error is! StorageFault &&
          error is! SqliteException &&
          error is! FileSystemException &&
          error is! PlatformException &&
          error is! StateError) {
        rethrow;
      }
      if (_recorder.isRecording) await _recorder.dispose();
      final problem = _problem(error);
      try {
        await _failed(problem);
      } finally {
        await _lease?.close();
        _lease = null;
        _active = null;
      }
      return Fail(problem);
    } finally {
      _busy = false;
    }
  }

  @override
  Future<Outcome<DumpRow?>> stopAndPersist() async {
    if (_busy) {
      return const Fail(
        (
          code: ProblemCode.busy,
          message: 'Recording operation is still running'
        ),
      );
    }
    final r = _active;
    if (r == null) return const Ok(null);
    _busy = true;
    try {
      final result = await _recorder.stop();
      if (result == null) {
        throw const StorageFault(
          (
            code: ProblemCode.interrupted,
            message: 'Recorder produced no known stopped result'
          ),
        );
      }
      if (result.path != r.stagingPath ||
          result.durationSeconds < 0 ||
          result.sizeBytes <= 0) {
        throw const StorageFault(
          (
            code: ProblemCode.invalid,
            message: 'Recorder result differs from reservation'
          ),
        );
      }
      _emit(CapturePhase.stopped);
      _emit(CapturePhase.publishing);
      final row = await _mutations.serialize(
        r.key,
        () => _persistence.save(r, result, now: _now(), lease: _lease!),
      );
      _emit(CapturePhase.committed);
      return Ok(row);
    } catch (error) {
      if (error is! StorageFault &&
          error is! SqliteException &&
          error is! FileSystemException &&
          error is! PlatformException &&
          error is! StateError) {
        rethrow;
      }
      if (_recorder.isRecording) await _recorder.dispose();
      final problem = _problem(error);
      await _failed(problem);
      return Fail(problem);
    } finally {
      await _lease?.close();
      _lease = null;
      _active = null;
      _busy = false;
    }
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:uuid/uuid.dart';
import '../local_db.dart';
import 'storage_codec.dart';
import 'storage_contract.dart';

/// App-owned admission registry. Disposing an observer never disposes this owner.
class DefaultRecordingMutationCoordinator
    implements RecordingMutationCoordinator {
  DefaultRecordingMutationCoordinator({required LocalDb db}) : _db = db;
  final LocalDb _db;
  @override
  final String processEpoch = const Uuid().v4();
  final _uses = <String, Set<_Lease>>{};
  final _lanes = <RecordingKey, Future<void>>{};
  final _queued = <String, int>{};
  final _changes = StreamController<void>.broadcast();
  final _restored = <Future<void>>{};
  Future<void>? _restoring;
  Future<void> _catalog = Future<void>.value();
  bool _ready = false;
  @override
  bool get hasActiveCapture =>
      _uses.values.expand((s) => s).any((l) => l.kind == UseKind.capture);
  void _changed() => _changes.add(null);
  StorageFault _fault(ProblemCode code, String message) =>
      StorageFault((code: code, message: message));

  @override
  Future<void> restoreFences({Iterable<RestoredUse> unsettled = const []}) {
    for (final use in unsettled) {
      if (!_restored.add(use.settled)) continue;
      final lease = _Lease(this, use.key, use.kind);
      (_uses[use.key.dumpId] ??= {}).add(lease);
      lease.retain();
      unawaited(
        use.settled.then(
          (_) {
            lease.release();
          },
          onError: (Object _, StackTrace __) {
            // A broken adapter did not prove termination. Keep its pin fail-closed.
          },
        ),
      );
      unawaited(lease.close());
    }
    _changed();
    return _restoring ??= _restore();
  }

  Future<void> _restore() async {
    try {
      // Query all states, including completed retirement receipts, before opening admission.
      await _db.select(_db.localDeletionTickets).get();
      _ready = true;
      _changed();
    } catch (_) {
      _restoring = null;
      rethrow;
    }
  }

  bool _exclusive(UseKind kind) =>
      kind == UseKind.deletion || kind == UseKind.capture;
  @override
  Future<Outcome<UseLease>> acquire(
    String dumpId,
    UseKind kind, {
    String? expectedIncarnation,
    String? retryTicketId,
  }) async {
    if (!_ready) {
      return const Fail(
        (code: ProblemCode.unavailable, message: 'Storage fences not restored'),
      );
    }
    StorageCodec.validateLiteralId(dumpId);
    if (expectedIncarnation != null) {
      StorageCodec.validateLiteralId(expectedIncarnation);
    }
    final active = _uses[dumpId] ?? {};
    if (active.any((l) => _exclusive(l.kind)) ||
        (_exclusive(kind) &&
            (active.isNotEmpty || (_queued[dumpId] ?? 0) != 0))) {
      return const Fail(
        (code: ProblemCode.busy, message: 'Recording is in use'),
      );
    }
    // Reserve synchronously, before the first database await.
    final lease = _Lease(
      this,
      (dumpId: dumpId, incarnation: expectedIncarnation ?? ''),
      kind,
    );
    (_uses[dumpId] ??= {}).add(lease);
    _changed();
    try {
      await _db.transaction(() async {
        if (kind == UseKind.deletion && await _db.hasCaptureJournal(dumpId)) {
          throw _fault(ProblemCode.busy, 'Owned staging cleanup is pending');
        }
        final ticket = await (_db.select(_db.localDeletionTickets)
              ..where((t) => t.dumpId.equals(dumpId)))
            .getSingleOrNull();
        if (ticket != null) {
          if (ticket.state == 'completed') {
            throw _fault(ProblemCode.retired, 'Recording ID is retired');
          }
          if (kind != UseKind.deletion || retryTicketId != ticket.ticketId) {
            throw _fault(
              ProblemCode.fenced,
              'Deletion requires explicit retry',
            );
          }
          final binding = StorageCodec.decodeBinding(ticket.bindingJson);
          if (expectedIncarnation != null &&
              binding.key.incarnation != expectedIncarnation) {
            throw _fault(
              ProblemCode.wrongIncarnation,
              'Wrong recording incarnation',
            );
          }
          final row = await _db.getDump(dumpId);
          if (row == null || await _db.boundRecording(dumpId) != binding) {
            throw _fault(ProblemCode.wrongIncarnation, 'Retry binding changed');
          }
          if (!['not_transcribed', 'completed', 'failed', 'not_applicable']
                  .contains(row.transcriptionStatus) ||
              row.syncStatus == 'syncing' ||
              (row.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                  false)) {
            throw _fault(ProblemCode.busy, 'Durable work is pending');
          }
          lease.key = binding.key;
          lease.binding = binding;
          return;
        }
        if (retryTicketId != null) {
          throw _fault(ProblemCode.conflict, 'Retry ticket does not exist');
        }
        final row = await _db.getDump(dumpId);
        final binding = await _db.boundRecording(dumpId);
        if (row == null &&
            kind == UseKind.capture &&
            expectedIncarnation != null &&
            binding == null) {
          final reservation = await (_db.select(_db.captureReservations)
                ..where((r) => r.dumpId.equals(dumpId)))
              .getSingleOrNull();
          if (reservation != null &&
              reservation.incarnation != expectedIncarnation) {
            throw _fault(
              ProblemCode.wrongIncarnation,
              'Capture identity conflict',
            );
          }
          return;
        }
        if (row == null) {
          throw _fault(ProblemCode.absent, 'Recording is missing');
        }
        if (binding == null) {
          throw _fault(
            ProblemCode.unresolved,
            'Original storage is unresolved',
          );
        }
        if (kind == UseKind.capture) {
          throw _fault(ProblemCode.conflict, 'Capture ID already exists');
        }
        if (expectedIncarnation != null &&
            binding.key.incarnation != expectedIncarnation) {
          throw _fault(
            ProblemCode.wrongIncarnation,
            'Wrong recording incarnation',
          );
        }
        if (kind == UseKind.deletion || kind == UseKind.acceptance) {
          if (!['not_transcribed', 'completed', 'failed', 'not_applicable']
                  .contains(row.transcriptionStatus) ||
              row.syncStatus == 'syncing' ||
              (row.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                  false)) {
            throw _fault(ProblemCode.busy, 'Durable work is pending');
          }
        }
        lease.key = binding.key;
        lease.binding = binding;
      });
      return Ok(lease);
    } on StorageFault catch (e) {
      await lease.close();
      return Fail(e.problem);
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  void _remove(_Lease lease) {
    final uses = _uses[lease.key.dumpId];
    uses?.remove(lease);
    if (uses?.isEmpty ?? false) _uses.remove(lease.key.dumpId);
    _changed();
  }

  @override
  Future<T> runIo<T>(UseLease lease, IoOperation<T> Function() start) async {
    if (lease is! _Lease || !identical(lease.owner, this)) {
      throw _fault(ProblemCode.invalid, 'Foreign use lease');
    }
    lease.retain();
    late IoOperation<T> operation;
    try {
      operation = start();
    } catch (_) {
      lease.release();
      rethrow;
    }
    unawaited(
      operation.settled.then(
        (_) {
          lease.release();
        },
        onError: (Object _, StackTrace __) {
          // Rejection is not proof that underlying work stopped. Retain the pin.
        },
      ),
    );
    return operation.result;
  }

  @override
  Future<T> serialize<T>(RecordingKey key, Future<T> Function() operation) {
    StorageCodec.encodeKey(key);
    if (!_ready ||
        (_uses[key.dumpId]?.any((l) => l.kind == UseKind.deletion) ?? false)) {
      throw _fault(ProblemCode.fenced, 'Publication not admitted');
    }
    final previous = _lanes[key] ?? Future<void>.value();
    final done = Completer<void>();
    _lanes[key] = done.future;
    _queued.update(key.dumpId, (n) => n + 1, ifAbsent: () => 1);
    _changed();
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        _queued.update(key.dumpId, (n) => n - 1);
        if (_queued[key.dumpId] == 0) _queued.remove(key.dumpId);
        if (identical(_lanes[key], done.future)) unawaited(_lanes.remove(key));
        done.complete();
        _changed();
      }
    }();
  }

  @override
  Future<T> catalogAdmission<T>(Future<T> Function() operation) {
    final previous = _catalog;
    final done = Completer<void>();
    _catalog = done.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        done.complete();
      }
    }();
  }

  Future<Map<String, Eligibility>> _eligibility() async {
    final result = <String, Eligibility>{};
    await _db.transaction(() async {
      final tickets = {
        for (final t in await _db.select(_db.localDeletionTickets).get())
          t.dumpId: t,
      };
      final journals = {
        for (final r in await _db.select(_db.captureReservations).get())
          r.dumpId,
      };
      final bindings = {
        for (final b in await _db.select(_db.recordingBindings).get())
          b.dumpId: b,
      };
      for (final row in await _db.select(_db.dumps).get()) {
        final ticket = tickets[row.id];
        result[row.id] = !_ready
            ? Eligibility.unresolved
            : ticket?.state == 'completed'
                ? Eligibility.retired
                : ticket != null
                    ? Eligibility.retryOnly
                    : (_uses[row.id]?.isNotEmpty ?? false) ||
                            (_queued[row.id] ?? 0) > 0
                        ? Eligibility.busy
                        : !const [
                            'not_transcribed',
                            'completed',
                            'failed',
                            'not_applicable',
                          ].contains(row.transcriptionStatus)
                            ? Eligibility.nonterminal
                            : row.syncStatus == 'syncing'
                                ? Eligibility.syncing
                                : journals.contains(row.id) ||
                                        (row.transcriptionError?.startsWith(
                                              'sidecar_sync_pending:',
                                            ) ??
                                            false)
                                    ? Eligibility.publicationPending
                                    : bindings[row.id]?.resolved != true
                                        ? Eligibility.unresolved
                                        : Eligibility.eligible;
      }
      for (final t in tickets.values) {
        result.putIfAbsent(
          t.dumpId,
          () => t.state == 'completed'
              ? Eligibility.retired
              : Eligibility.retryOnly,
        );
      }
    });
    return Map.unmodifiable(result);
  }

  @override
  Stream<Map<String, Eligibility>> watchEligibility() => Stream.multi((sink) {
        var canceled = false;
        var queue = Future<void>.value();
        void emit() {
          queue = queue.then((_) async {
            if (canceled) return;
            try {
              final snapshot = await _eligibility();
              if (!canceled) sink.add(snapshot);
            } catch (e, st) {
              if (!canceled) sink.addError(e, st);
            }
          });
        }

        final memory = _changes.stream.listen((_) => emit());
        final database = _db
            .customSelect(
              'SELECT id FROM dumps',
              readsFrom: {
                _db.dumps,
                _db.recordingBindings,
                _db.storageLocations,
                _db.localDeletionTickets,
                _db.captureReservations,
              },
            )
            .watch()
            .listen((_) => emit(), onError: sink.addError);
        emit();
        sink.onCancel = () async {
          canceled = true;
          await memory.cancel();
          await database.cancel();
          await queue;
        };
      });
  @override
  Future<void> drain() async {
    while (true) {
      final catalog = _catalog;
      await Future.wait([
        catalog,
        ..._uses.values.expand((s) => s).map((l) => l.done.future),
        ..._lanes.values,
      ]);
      if (_uses.isEmpty && _lanes.isEmpty && identical(catalog, _catalog)) {
        return;
      }
    }
  }
}

final class _Lease implements UseLease {
  _Lease(this.owner, this.key, this.kind);
  final DefaultRecordingMutationCoordinator owner;
  @override
  RecordingKey key;
  final UseKind kind;
  @override
  BoundRecording? binding;
  final done = Completer<void>();
  int children = 0;
  bool closing = false;
  void retain() {
    if (closing) {
      throw const StorageFault(
        (code: ProblemCode.fenced, message: 'Use lease is closing'),
      );
    }
    children++;
  }

  void release() {
    children--;
    _finish();
  }

  void _finish() {
    if (closing && children == 0 && !done.isCompleted) {
      owner._remove(this);
      done.complete();
    }
  }

  @override
  Future<void> close() {
    closing = true;
    _finish();
    return done.future;
  }
}

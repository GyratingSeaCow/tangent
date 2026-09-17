// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart' show SqliteException;
import '../local_db.dart';
import 'storage_codec.dart';
import 'storage_contract.dart';

/// Confirmation owns a frozen payload. Startup/replay never resumes destruction.
class DefaultLocalDeletionService implements LocalDeletionService {
  DefaultLocalDeletionService({
    required LocalDb db,
    required StorageBackend backend,
    required RecordingMutationCoordinator mutations,
  })  : _db = db,
        _backend = backend,
        _mutations = mutations;
  final LocalDb _db;
  final StorageBackend _backend;
  final RecordingMutationCoordinator _mutations;
  // Sharing is per app DB, not per replaceable service. SQLite remains authority
  // across a cold connection, where pending batches replay their saved progress.
  static final _inflight = Expando<
      Map<String,
          ({String payload, Future<Outcome<BulkDeletionResult>> result})>>();
  static const ComponentResult _pending =
      (state: ComponentState.pending, problem: null);
  StorageProblem _problem(ProblemCode code) =>
      (code: code, message: 'Local deletion: ${code.name}');
  Never _fault(ProblemCode code) => throw StorageFault(_problem(code));
  T _value<T>(Outcome<T> result) => switch (result) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem)
      };
  bool _gone(ComponentResult c) =>
      c.state == ComponentState.removed || c.state == ComponentState.absent;
  @override
  Stream<Map<String, Eligibility>> watchEligibility() =>
      _mutations.watchEligibility();

  Future<Outcome<T>> _boundary<T>(Future<Outcome<T>> Function() body) async {
    try {
      return await body();
    } on StorageFault catch (e) {
      return Fail(_problem(e.problem.code));
    } on SqliteException {
      return Fail(_problem(ProblemCode.persistence));
    } on FileSystemException {
      return Fail(_problem(ProblemCode.io));
    } on FormatException {
      return Fail(_problem(ProblemCode.invalid));
    } on TypeError {
      return Fail(_problem(ProblemCode.invalid));
    }
  }

  @override
  Future<Outcome<DeletionPreview>> preview(Set<String> selectedIds) {
    final ids = selectedIds.toList()..sort();
    return _boundary(() async {
      for (final id in ids) {
        StorageCodec.validateLiteralId(id);
      }
      final eligibility = await watchEligibility().first;
      return _db.transaction(() async {
        final targets = <DeleteTarget>[];
        for (final id in ids) {
          final row = await _db.getDump(id);
          final ticket = await (_db.select(_db.localDeletionTickets)
                ..where((t) => t.dumpId.equals(id)))
              .getSingleOrNull();
          targets.add(
            (
              id: id,
              binding: ticket == null
                  ? await _db.boundRecording(id)
                  : StorageCodec.decodeBinding(ticket.bindingJson),
              title: row?.title ?? '',
              eligibility: eligibility[id] ?? Eligibility.missing,
              retryTicketId: ticket?.ticketId
            ),
          );
        }
        return Ok((targets: List<DeleteTarget>.unmodifiable(targets)));
      });
    });
  }

  Map<String, Object?> _target(DeleteTarget t) => {
        'id': t.id,
        'binding':
            t.binding == null ? null : StorageCodec.encodeBinding(t.binding!),
        'eligibility': t.eligibility.name,
        'retryTicketId': t.retryTicketId,
      };
  Map<String, Object?>? _problemMap(StorageProblem? p) =>
      p == null ? null : {'code': p.code.name};
  Map<String, Object?> _componentMap(ComponentResult c) =>
      {'state': c.state.name, 'problem': _problemMap(c.problem)};
  String _encode(List<DeletionItemResult> items) => jsonEncode(
        items
            .map(
              (i) => {
                'id': i.id,
                'state': i.state.name,
                'audio': _componentMap(i.audio),
                'metadata': _componentMap(i.metadata),
                'ticketId': i.ticketId,
                'problem': _problemMap(i.problem),
              },
            )
            .toList(),
      );
  List<DeletionItemResult> _decode(String raw) {
    StorageProblem? problem(dynamic p) => p == null
        ? null
        : _problem(ProblemCode.values.byName(p['code'] as String));
    ComponentResult component(dynamic c) => (
          state: ComponentState.values.byName(c['state'] as String),
          problem: problem(c['problem'])
        );
    return List<DeletionItemResult>.unmodifiable(
      (jsonDecode(raw) as List).map(
        (dynamic i) => (
          id: i['id'] as String,
          state: DeleteState.values.byName(i['state'] as String),
          audio: component(i['audio']),
          metadata: component(i['metadata']),
          ticketId: i['ticketId'] as String?,
          problem: problem(i['problem'])
        ),
      ),
    );
  }

  DeletionItemResult _item(
    String id,
    DeleteState state, {
    DeletionTicket? ticket,
    StorageProblem? problem,
  }) =>
      (
        id: id,
        state: state,
        audio: ticket?.audio ?? _pending,
        metadata: ticket?.metadata ?? _pending,
        ticketId: ticket?.id,
        problem: problem == null ? null : _problem(problem.code)
      );

  @override
  Future<Outcome<BulkDeletionResult>> deleteConfirmed(
    ConfirmedDeletion request,
  ) =>
      _boundary(() async {
        // Copy before first await. Titles are presentation only, never persisted.
        final byId = <String, DeleteTarget>{};
        for (final t in request.targets) {
          StorageCodec.validateLiteralId(t.id);
          if (t.binding != null && t.binding!.key.dumpId != t.id) {
            _fault(ProblemCode.invalid);
          }
          if (byId.containsKey(t.id) &&
              jsonEncode(_target(byId[t.id]!)) != jsonEncode(_target(t))) {
            _fault(ProblemCode.conflict);
          }
          byId[t.id] = (
            id: t.id,
            binding: t.binding,
            title: '',
            eligibility: t.eligibility,
            retryTicketId: t.retryTicketId
          );
        }
        final ids = byId.keys.toList()..sort();
        final targets = ids.map((id) => byId[id]!).toList(growable: false);
        final payload = jsonEncode({
          'version': 1,
          'kind': 'delete',
          'targets': targets.map(_target).toList(),
        });
        return _batch(
          request.operationId,
          payload,
          targets
              .map(
                (t) => _item(
                  t.id,
                  DeleteState.failed,
                  problem: _problem(ProblemCode.interrupted),
                ),
              )
              .toList(),
          () async => [
            for (final t in targets) await _delete(request.operationId, t),
          ],
        );
      });

  @override
  Future<Outcome<BulkDeletionResult>> retryConfirmed(
    ConfirmedDeletionRetry request,
  ) =>
      _boundary(() async {
        final ids = request.ticketIds.toSet().toList()..sort();
        for (final id in ids) {
          StorageCodec.validateLiteralId(id);
        }
        final payload =
            jsonEncode({'version': 1, 'kind': 'retry', 'ticketIds': ids});
        // Resolve every immutable ticket before accepting the batch. A cold
        // replay must retain membership even if the first retry never settles.
        final tickets = <DeletionTicket>[];
        for (final id in ids) {
          final ticket = await _db.deletionTicketById(id);
          if (ticket == null) {
            _fault(ProblemCode.invalid);
          }
          tickets.add(ticket);
        }
        final initial = [
          for (final ticket in tickets)
            _item(
              ticket.binding.key.dumpId,
              ticket.state == TicketState.completed
                  ? DeleteState.deleted
                  : DeleteState.failed,
              ticket: ticket,
              problem: ticket.state == TicketState.completed
                  ? null
                  : _problem(ProblemCode.interrupted),
            ),
        ];
        // Retry identity is only the immutable ticket ID, never the current row/root.
        return _batch(request.operationId, payload, initial, () async {
          final results = <DeletionItemResult>[];
          for (final ticket in tickets) {
            if (ticket.state == TicketState.completed) {
              results.add(
                _item(
                  ticket.binding.key.dumpId,
                  DeleteState.deleted,
                  ticket: ticket,
                ),
              );
            } else {
              results.add(
                await _delete(
                  request.operationId,
                  (
                    id: ticket.binding.key.dumpId,
                    binding: ticket.binding,
                    title: '',
                    eligibility: Eligibility.retryOnly,
                    retryTicketId: ticket.id
                  ),
                  retry: true,
                ),
              );
            }
          }
          return results;
        });
      });

  Future<Outcome<BulkDeletionResult>> _batch(
    String id,
    String payload,
    List<DeletionItemResult> initial,
    Future<List<DeletionItemResult>> Function() work,
  ) async {
    StorageCodec.validateLiteralId(id);
    final running = _inflight[_db] ??= {};
    final prior = running[id];
    if (prior != null) {
      if (prior.payload != payload) {
        _fault(ProblemCode.conflict);
      }
      final value = _value(await prior.result);
      return Ok((items: value.items, replayed: true));
    }
    final future = _boundary<BulkDeletionResult>(() async {
      final old = await _db.transaction(() async {
        final row = await (_db.select(_db.localDeletionBatches)
              ..where((b) => b.operationId.equals(id)))
            .getSingleOrNull();
        if (row != null) {
          if (row.payloadJson != payload) {
            _fault(ProblemCode.conflict);
          }
          return row;
        }
        await _db.into(_db.localDeletionBatches).insert(
              LocalDeletionBatchesCompanion.insert(
                operationId: id,
                payloadJson: payload,
                resultsJson: _encode(initial),
                state: 'pending',
              ),
            );
        return null;
      });
      if (old != null) {
        return Ok((items: _decode(old.resultsJson), replayed: true));
      }
      final items = await work();
      await (_db.update(_db.localDeletionBatches)
            ..where(
              (b) =>
                  b.operationId.equals(id) &
                  b.payloadJson.equals(payload) &
                  b.state.equals('pending'),
            ))
          .write(
        LocalDeletionBatchesCompanion(
          resultsJson: Value(_encode(items)),
          state: const Value('completed'),
        ),
      );
      return Ok(
        (items: List<DeletionItemResult>.unmodifiable(items), replayed: false),
      );
    });
    running[id] = (payload: payload, result: future);
    try {
      return await future;
    } finally {
      running.remove(id);
    }
  }

  Future<void> _progress(String operationId, DeletionItemResult item) =>
      _db.transaction(() async {
        final batch = await (_db.select(_db.localDeletionBatches)
              ..where((b) => b.operationId.equals(operationId)))
            .getSingle();
        if (batch.state != 'pending') {
          _fault(ProblemCode.conflict);
        }
        final items = _decode(batch.resultsJson).toList();
        final index = items.indexWhere((i) => i.id == item.id);
        if (index < 0) {
          items.add(item);
        } else {
          items[index] = item;
        }
        await (_db.update(_db.localDeletionBatches)
              ..where((b) => b.operationId.equals(operationId)))
            .write(
          LocalDeletionBatchesCompanion(
            resultsJson: Value(_encode(items)),
          ),
        );
      });

  Future<DeletionItemResult> _delete(
    String operationId,
    DeleteTarget target, {
    bool retry = false,
  }) async {
    final result = await _deleteOne(operationId, target, retry: retry);
    await _progress(operationId, result);
    return result;
  }

  Future<DeletionItemResult> _deleteOne(
    String operationId,
    DeleteTarget target, {
    bool retry = false,
  }) async {
    final binding = target.binding;
    if (binding == null ||
        (!retry && target.eligibility != Eligibility.eligible)) {
      return _item(
        target.id,
        DeleteState.skipped,
        problem: _problem(
          binding == null ? ProblemCode.unresolved : ProblemCode.busy,
        ),
      );
    }
    UseLease? lease;
    DeletionTicket? ticket;
    StorageProblem? failure;
    try {
      lease = _value<UseLease>(
        await _mutations.acquire(
          target.id,
          UseKind.deletion,
          expectedIncarnation: binding.key.incarnation,
          retryTicketId: retry ? target.retryTicketId : null,
        ),
      );
      if (lease.binding != binding) {
        _fault(ProblemCode.wrongIncarnation);
      }
      ticket = _value<DeletionTicket>(
        await _db.claimLocalDeletion(operationId, target),
      );
      final ticketId = ticket.id;
      await _progress(
        operationId,
        _item(
          target.id,
          DeleteState.failed,
          ticket: ticket,
          problem: _problem(ProblemCode.interrupted),
        ),
      );
      for (final component in RecordingComponent.values) {
        final current = ticket!;
        final previous = component == RecordingComponent.audio
            ? current.audio
            : current.metadata;
        if (_gone(previous)) {
          continue;
        }
        IoOperation<ComponentResult>? io;
        ComponentResult result;
        try {
          result = await _mutations.runIo(
            lease,
            () => io = _backend.deleteComponent(
              binding,
              component,
              '$operationId-$ticketId-${component.name}',
            ),
          );
        } on StorageFault catch (e) {
          result = (
            state: ComponentState.unknown,
            problem: _problem(e.problem.code)
          );
        } on FileSystemException {
          result = (
            state: ComponentState.unknown,
            problem: _problem(ProblemCode.io)
          );
        } finally {
          await io?.settled; // A failed observer is not worker termination.
        }
        result = (
          state: result.state,
          problem:
              result.problem == null ? null : _problem(result.problem!.code)
        );
        await _db.recordDeletionComponent(ticketId, component, result);
        ticket = (await _db.deletionTicketById(ticketId))!;
        await _progress(
          operationId,
          _item(
            target.id,
            DeleteState.failed,
            ticket: ticket,
            problem: result.problem ?? _problem(ProblemCode.interrupted),
          ),
        );
        if (!_gone(result)) {
          return _item(
            target.id,
            DeleteState.failed,
            ticket: ticket,
            problem: result.problem ?? _problem(ProblemCode.unknown),
          );
        }
      }
      await _db.finishLocalDeletion(ticketId);
      ticket = (await _db.deletionTicketById(ticketId))!;
      return _item(target.id, DeleteState.deleted, ticket: ticket);
    } on StorageFault catch (e) {
      failure = _problem(e.problem.code);
    } on SqliteException {
      failure = _problem(ProblemCode.persistence);
    } finally {
      await lease?.close();
    }
    return _item(
      target.id,
      ticket == null ? DeleteState.skipped : DeleteState.failed,
      ticket: ticket,
      problem: failure,
    );
  }
}

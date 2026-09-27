// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../screens/home/home_screen.dart' show localDbProvider;
import 'local_db.dart';

/// Local persistence for to-do items (To Do arc Phase 1).
///
/// Follows the notebook repository's shape: every write stamps a fresh
/// `updated_at` and marks the row dirty, in the one place writes funnel
/// through — a write that forgot the flag would be invisible to the user's
/// other devices with nothing to reveal it.
///
/// Deletion is SOFT (`deleted_at` on the row, no tombstone): the 5-second
/// undo snackbar needs the row back verbatim, and the deletion travels to
/// peers as an ordinary dirty upsert carrying the field.
class TodoRepository {
  TodoRepository({
    required LocalDb db,
    String Function()? idFactory,
    DateTime Function()? now,
  })  : _db = db,
        _idFactory = idFactory ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now;

  final LocalDb _db;
  final String Function() _idFactory;
  final DateTime Function() _now;

  String _stamp() => _now().toUtc().toIso8601String();

  /// Every live (non-deleted) todo, oldest first so the UI's sections keep
  /// entry order. Sectioning happens in the UI layer, not here.
  Stream<List<TodoRow>> watchTodos() => (_db.select(_db.todos)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
      .watch();

  /// Every todo carrying [sourceRef] as its provenance, live OR soft-deleted,
  /// oldest first. Soft-deleted rows are deliberately included: this is the
  /// idempotency oracle for voice capture, and an Undone dump must stay undone
  /// (a re-sync that only looked at live rows would resurrect the items).
  Future<List<TodoRow>> todosFromSource(String sourceRef) =>
      (_db.select(_db.todos)
            ..where((t) => t.sourceRef.equals(sourceRef))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  /// True when anything was ever captured for [sourceRef] — including items
  /// the user has since Undone or deleted.
  Future<bool> hasTodosFromSource(String sourceRef) async =>
      (await todosFromSource(sourceRef)).isNotEmpty;

  /// The LIVE voice todos captured from [sourceRef], for the detail screen's
  /// "Added to your To Do list" card. Empty once the user hits Undo, which is
  /// what hides the card.
  Stream<List<TodoRow>> watchTodosFromSource(String sourceRef) =>
      (_db.select(_db.todos)
            ..where(
              (t) => t.sourceRef.equals(sourceRef) & t.deletedAt.isNull(),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  /// Adds a new open todo. [dueDate] is an ISO `YYYY-MM-DD` or null.
  ///
  /// [source]/[sourceRef] are phase 1's reserved provenance fields; voice
  /// capture writes `source: 'voice'` with the dump id as the ref.
  Future<TodoRow> add(
    String text, {
    String? dueDate,
    String? source,
    String? sourceRef,
  }) async {
    final String timestamp = _stamp();
    final String id = _idFactory();
    await _db.into(_db.todos).insert(
          TodosCompanion.insert(
            id: id,
            body: text,
            createdAt: timestamp,
            updatedAt: timestamp,
            dueDate: Value(dueDate),
            source: source == null ? const Value.absent() : Value(source),
            sourceRef: Value(sourceRef),
            syncDirty: const Value(true),
          ),
        );
    return (await _db.getTodoRow(id))!;
  }

  /// Soft-deletes every live todo captured from [sourceRef] (the card's Undo).
  /// The rows stay as tombstoned provenance, so [hasTodosFromSource] keeps
  /// answering true and detection never re-fires for that dump.
  Future<int> softDeleteFromSource(String sourceRef) async {
    final List<TodoRow> rows = await watchTodosFromSource(sourceRef).first;
    for (final TodoRow row in rows) {
      await softDelete(row.id);
    }
    return rows.length;
  }

  /// Checks an open item (stamps `done_at`) or unchecks a done one
  /// (clears it). Nothing ever auto-deletes.
  Future<void> toggle(String id) async {
    final TodoRow? row = await _db.getTodoRow(id);
    if (row == null) return;
    await _write(
      id,
      TodosCompanion(
        doneAt: Value(row.doneAt == null ? _stamp() : null),
      ),
    );
  }

  Future<void> editText(String id, String text) async {
    await _write(id, TodosCompanion(body: Value(text)));
  }

  /// Sets or clears the due date. A cleared date is a real null on the
  /// row — indistinguishable from never-set in the sections (both read
  /// Someday), but the write still travels so peers converge.
  Future<void> setDueDate(String id, String? dueDate) async {
    await _write(id, TodosCompanion(dueDate: Value(dueDate)));
  }

  /// Soft delete: stamps `deleted_at`, keeps the row. The undo snackbar
  /// calls [restore] within its 5-second window; nothing purges the row
  /// locally either way — the field is the deletion.
  Future<void> softDelete(String id) async {
    await _write(id, TodosCompanion(deletedAt: Value(_stamp())));
  }

  /// Undoes a soft delete by clearing `deleted_at`.
  Future<void> restore(String id) async {
    await _write(id, const TodosCompanion(deletedAt: Value(null)));
  }

  Future<void> _write(String id, TodosCompanion changes) async {
    await (_db.update(_db.todos)..where((t) => t.id.equals(id))).write(
      changes.copyWith(
        updatedAt: Value(_stamp()),
        // Every local edit is unsynced work until the server confirms it.
        syncDirty: const Value(true),
      ),
    );
  }
}

final todoRepositoryProvider = Provider<TodoRepository>(
  (ref) => TodoRepository(db: ref.watch(localDbProvider)),
);

/// Live todo list for the To Do screen.
final todosProvider = StreamProvider<List<TodoRow>>(
  (ref) => ref.watch(todoRepositoryProvider).watchTodos(),
);

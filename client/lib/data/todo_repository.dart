// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../screens/home/home_screen.dart' show localDbProvider;
import 'local_db.dart';

const String defaultTodoColumnId = 'todo-column-todo';
const List<(String, String)> defaultTodoColumns = <(String, String)>[
  (defaultTodoColumnId, 'To Do'),
  ('todo-column-progress', 'In Progress'),
  ('todo-column-done', 'Done'),
];
const String _defaultColumnSeedStamp = '1970-01-01T00:00:00.000Z';

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
  Stream<List<TodoRow>> watchTodos() => _liveTodosQuery().watch();

  /// One-shot form of [watchTodos]. Prefer this over `watchTodos().first`
  /// anywhere the caller is not a long-lived listener — a drift stream's
  /// first emission is delivered through a `Timer.run`, which under a
  /// widget test's fake clock never fires until the tree is pumped, so
  /// `.first` there awaits forever.
  Future<List<TodoRow>> listTodos() => _liveTodosQuery().get();

  Stream<List<TodoColumnRow>> watchColumns() =>
      (_db.select(_db.todoColumns)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm.asc(c.sortOrder)]))
          .watch();

  Future<List<TodoColumnRow>> listColumns() =>
      (_db.select(_db.todoColumns)
            ..where((c) => c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm.asc(c.sortOrder)]))
          .get();

  /// Seeds conventional lanes and repairs orphaned references. The board calls
  /// this on open; add calls it too so list-created rows still get a lane.
  Future<List<TodoColumnRow>> ensureColumns() async {
    await _db.transaction(() async {
      List<TodoColumnRow> live = await listColumns();
      if (live.isEmpty) {
        for (int i = 0; i < defaultTodoColumns.length; i++) {
          final (String id, String name) = defaultTodoColumns[i];
          await _db
              .into(_db.todoColumns)
              .insert(
                TodoColumnsCompanion.insert(
                  id: id,
                  name: name,
                  sortOrder: i,
                  createdAt: _defaultColumnSeedStamp,
                  updatedAt: _defaultColumnSeedStamp,
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
        live = await listColumns();
        if (live.isEmpty) {
          // Every conventional id is already a tombstone. Never resurrect
          // those remote decisions; create one genuinely new fallback lane.
          final String stamp = _stamp();
          await _db
              .into(_db.todoColumns)
              .insert(
                TodoColumnsCompanion.insert(
                  id: 'todo-column-${_idFactory()}',
                  name: 'To Do',
                  sortOrder: 0,
                  createdAt: stamp,
                  updatedAt: stamp,
            ),
          );
        live = await listColumns();
      }
      }
      final String first = live.first.id;
      final List<TodoRow> rows = await _db.select(_db.todos).get();
      for (final TodoRow row in rows) {
        // A non-null unknown id may resolve on a later pull. Rehoming it now
        // would overwrite that placement, including on newer deleted rows.
        if (row.deletedAt != null || row.columnId != null) continue;
        await _write(row.id, TodosCompanion(columnId: Value(first)));
      }
    });
    return listColumns();
  }

  SimpleSelectStatement<$TodosTable, TodoRow> _liveTodosQuery() =>
      _db.select(_db.todos)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);

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
            ..where((t) => t.sourceRef.equals(sourceRef) & t.deletedAt.isNull())
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
    String? captureFingerprint,
  }) async {
    final List<TodoColumnRow> columns = await ensureColumns();
    final String columnId = columns.first.id;
    final int nextOrder = await _nextBoardOrder(columnId);
    final String timestamp = _stamp();
    final String id = _idFactory();
    await _db
        .into(_db.todos)
        .insert(
          TodosCompanion.insert(
            id: id,
            body: text,
            createdAt: timestamp,
            updatedAt: timestamp,
            dueDate: Value(dueDate),
            source: source == null ? const Value.absent() : Value(source),
            sourceRef: Value(sourceRef),
            captureFingerprint: Value(captureFingerprint),
            columnId: Value(columnId),
            boardOrder: Value(nextOrder),
            syncDirty: const Value(true),
          ),
        );
    return (await _db.getTodoRow(id))!;
  }

  /// Stamps the LOCAL-ONLY capture fingerprint on every row of [sourceRef]
  /// (live or soft-deleted). Deliberately NOT through [_write]: the column
  /// never syncs, so bumping `updated_at` or dirtying the rows would push
  /// a no-op edit to every peer.
  Future<void> setCaptureFingerprint(
    String sourceRef,
    String fingerprint,
  ) async {
    await (_db.update(_db.todos)..where((t) => t.sourceRef.equals(sourceRef)))
        .write(TodosCompanion(captureFingerprint: Value(fingerprint)));
  }

  /// Soft-deletes every live todo captured from [sourceRef] (the card's Undo).
  /// The rows stay as tombstoned provenance, so [hasTodosFromSource] keeps
  /// answering true and detection never re-fires for that dump.
  Future<int> softDeleteFromSource(String sourceRef) async {
    // A one-shot .get(), not the watch stream's .first: awaiting a stream
    // inside a widget-test pump serialises badly and the card never redrew.
    final List<TodoRow> rows =
        await (_db.select(_db.todos)..where(
              (t) => t.sourceRef.equals(sourceRef) & t.deletedAt.isNull(),
            ))
        .get();
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
      TodosCompanion(doneAt: Value(row.doneAt == null ? _stamp() : null)),
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

  /// Files the item under [folderId] (a shared `folders` row) or unfiles it
  /// with null. Goes through [_write] so `updated_at` bumps and the row is
  /// dirty — a move that kept the old stamp would lose to the server's
  /// newer-wins rule and silently never reach the other devices.
  Future<void> moveToFolder(String id, String? folderId) async {
    await _write(id, TodosCompanion(folderId: Value(folderId)));
  }

  /// Pins or unpins one item as a normal synced edit.
  Future<void> setPinned(String id, bool pinned) async {
    await _write(id, TodosCompanion(pinned: Value<bool?>(pinned)));
  }

  Future<int> _nextBoardOrder(String columnId) async {
    final List<TodoRow> rows = await (_db.select(
      _db.todos,
    )..where((t) => t.columnId.equals(columnId) & t.deletedAt.isNull())).get();
    if (rows.isEmpty) return 0;
    return rows.map((r) => r.boardOrder).reduce((a, b) => a > b ? a : b) + 1;
  }

  /// Moves [todoId] to [columnId] at [index], changing only the moved card and
  /// records whose integer position actually shifts.
  Future<void> moveOnBoard(String todoId, String columnId, int index) async {
    await _db.transaction(() async {
      final TodoRow? moving = await _db.getTodoRow(todoId);
      if (moving == null) return;
      final Set<String> laneIds = <String>{columnId};
      if (moving.columnId != null) laneIds.add(moving.columnId!);
      for (final String laneId in laneIds) {
        final List<TodoRow> lane =
            await (_db.select(_db.todos)
                  ..where(
                    (t) => t.columnId.equals(laneId) & t.deletedAt.isNull(),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.boardOrder)]))
                .get();
        final int oldLaneIndex = lane.indexWhere((row) => row.id == todoId);
        lane.removeWhere((row) => row.id == todoId);
        if (laneId == columnId) {
          final int adjusted =
              laneId == moving.columnId &&
                  oldLaneIndex >= 0 &&
                  oldLaneIndex < index
              ? index - 1
              : index;
          lane.insert(adjusted.clamp(0, lane.length), moving);
        }
        for (int i = 0; i < lane.length; i++) {
          if (lane[i].columnId == laneId && lane[i].boardOrder == i) continue;
          await _write(
            lane[i].id,
            TodosCompanion(columnId: Value(laneId), boardOrder: Value(i)),
          );
        }
      }
    });
  }

  Future<TodoColumnRow> addColumn(String rawName) async {
    final String name = rawName.trim();
    if (name.isEmpty) throw ArgumentError('Column name cannot be empty');
    final List<TodoColumnRow> columns = await ensureColumns();
    final String stamp = _stamp();
    final String id = 'todo-column-${_idFactory()}';
    await _db
        .into(_db.todoColumns)
        .insert(
          TodoColumnsCompanion.insert(
            id: id,
            name: name,
            sortOrder: columns.length,
            createdAt: stamp,
            updatedAt: stamp,
          ),
        );
    return (_db.select(
      _db.todoColumns,
    )..where((c) => c.id.equals(id))).getSingle();
  }

  Future<void> renameColumn(String id, String rawName) async {
    final String name = rawName.trim();
    if (name.isEmpty) throw ArgumentError('Column name cannot be empty');
    final int changed =
        await (_db.update(
          _db.todoColumns,
        )..where((c) => c.id.equals(id) & c.deletedAt.isNull())).write(
      TodoColumnsCompanion(
        name: Value(name),
        updatedAt: Value(_stamp()),
        syncDirty: const Value(true),
      ),
    );
    if (changed != 1) throw StateError('Column is not live: $id');
  }

  Future<void> reorderColumn(String id, int newIndex) async {
    await _db.transaction(() async {
      final List<TodoColumnRow> columns = await listColumns();
      final int oldIndex = columns.indexWhere((c) => c.id == id);
      if (oldIndex < 0) return;
      final TodoColumnRow row = columns.removeAt(oldIndex);
      columns.insert(newIndex.clamp(0, columns.length), row);
      final String stamp = _stamp();
      for (int i = 0; i < columns.length; i++) {
        await (_db.update(
          _db.todoColumns,
        )..where((c) => c.id.equals(columns[i].id))).write(
          TodoColumnsCompanion(
            sortOrder: Value(i),
            updatedAt: Value(stamp),
            syncDirty: const Value(true),
          ),
        );
      }
    });
  }

  /// Moves all cards, then retires the lane in the same transaction.
  Future<void> deleteColumn(String id, String destinationId) async {
    await _db.transaction(() async {
      final List<TodoColumnRow> columns = await listColumns();
      if (columns.length <= 1) {
        throw StateError('A board needs at least one column');
      }
      if (!columns.any((c) => c.id == id)) {
        throw StateError('Column is not live: $id');
      }
      if (id == destinationId || !columns.any((c) => c.id == destinationId)) {
        throw ArgumentError('Choose another live destination column');
      }
      final List<TodoRow> cards =
          await (_db.select(_db.todos)
                ..where((t) => t.columnId.equals(id))
                ..orderBy([(t) => OrderingTerm.asc(t.boardOrder)]))
              .get();
      int order = await _nextBoardOrder(destinationId);
      for (final TodoRow card in cards) {
        await _write(
          card.id,
          TodosCompanion(
            columnId: Value(destinationId),
            boardOrder: Value(order++),
          ),
        );
      }
      final String stamp = _stamp();
      await (_db.update(_db.todoColumns)..where((c) => c.id.equals(id))).write(
        TodoColumnsCompanion(
          deletedAt: Value(stamp),
          updatedAt: Value(stamp),
          syncDirty: const Value(true),
        ),
      );
    });
  }

  Future<int> countTodosInColumn(String id) async {
    final Expression<int> count = _db.todos.id.count();
    final query = _db.selectOnly(_db.todos)
      ..addColumns(<Expression<Object>>[count])
      ..where(_db.todos.columnId.equals(id));
    return (await query.getSingle()).read(count) ?? 0;
  }

  /// [moveToFolder] for a multi-select set, one transaction.
  Future<void> moveManyToFolder(Iterable<String> ids, String? folderId) async {
    await _db.transaction(() async {
      for (final String id in ids) {
        await moveToFolder(id, folderId);
      }
    });
  }

  /// Marks every OPEN item in [ids] done (already-done ones are left alone,
  /// unlike [toggle]). The multi-select toolbar's "Done".
  Future<void> markManyDone(Iterable<String> ids) async {
    await _db.transaction(() async {
      for (final String id in ids) {
        final TodoRow? row = await _db.getTodoRow(id);
        if (row == null || row.doneAt != null) continue;
        await _write(id, TodosCompanion(doneAt: Value(_stamp())));
      }
    });
  }

  /// Soft-deletes the whole set in one transaction; [restoreMany] undoes it.
  Future<void> softDeleteMany(Iterable<String> ids) async {
    await _db.transaction(() async {
      for (final String id in ids) {
        await softDelete(id);
      }
    });
  }

  Future<void> restoreMany(Iterable<String> ids) async {
    await _db.transaction(() async {
      for (final String id in ids) {
        await restore(id);
      }
    });
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

final todoColumnsProvider = StreamProvider<List<TodoColumnRow>>(
  (ref) => ref.watch(todoRepositoryProvider).watchColumns(),
);

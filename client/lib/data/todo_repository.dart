// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../screens/home/home_screen.dart' show localDbProvider;
import 'local_db.dart';

const String defaultTodoColumnId = 'todo-column-todo';
const String _voiceTodoSource = 'voice';
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
  }) : _db = db,
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
        // Intentional: live.first differs from restorePendingTodoBoardPlacement's fixed lane.
        await _write(row.id, TodosCompanion(columnId: Value(first)));
      }
    });
    return listColumns();
  }

  SimpleSelectStatement<$TodosTable, TodoRow> _liveTodosQuery() =>
      _db.select(_db.todos)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);

  /// Every voice-captured todo carrying [sourceRef] as its provenance, live OR
  /// soft-deleted, oldest first. A manual card may retain the same dump ref for
  /// tap-through without joining this voice-capture spine. Soft-deleted voice
  /// rows are deliberately included: this is the idempotency oracle, and an
  /// Undone dump must stay undone (a live-only query would resurrect items).
  Future<List<TodoRow>> todosFromSource(String sourceRef) =>
      (_db.select(_db.todos)
            ..where(
              (t) =>
                  t.source.equals(_voiceTodoSource) &
                  t.sourceRef.equals(sourceRef),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  /// True when any voice todo was ever captured for [sourceRef] — including
  /// items the user has since Undone or deleted. Manual cards do not suppress
  /// voice detection even when they retain that dump as provenance.
  Future<bool> hasTodosFromSource(String sourceRef) async =>
      (await todosFromSource(sourceRef)).isNotEmpty;

  /// The LIVE voice todos captured from [sourceRef], for the detail screen's
  /// "Added to your To Do list" card. Empty once the user hits Undo, which is
  /// what hides the card.
  Stream<List<TodoRow>> watchTodosFromSource(String sourceRef) =>
      (_db.select(_db.todos)
            ..where(
              (t) =>
                  t.source.equals(_voiceTodoSource) &
                  t.sourceRef.equals(sourceRef) &
                  t.deletedAt.isNull(),
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

  /// Creates one open card at the bottom of the chosen live Kanban lane.
  /// Text is stored exactly as supplied; callers own any user-facing editing.
  Future<TodoRow> addToColumn(
    String text,
    String columnId, {
    required String sourceRef,
  }) async {
    return (await addManyToColumn(columnId, <({String text, String sourceRef})>[
      (text: text, sourceRef: sourceRef),
    ])).single;
  }

  /// Appends open cards to [columnId] in [drafts] iteration order.
  ///
  /// Validation, order allocation, and every insert share one transaction, so
  /// a failed card cannot leave a partial recording batch on the board. The
  /// insert fields intentionally mirror [add]: manual source/default folder,
  /// open state, and dirty sync state, with only dump provenance added.
  Future<List<TodoRow>> addManyToColumn(
    String columnId,
    Iterable<({String text, String sourceRef})> drafts,
  ) async {
    final List<({String text, String sourceRef})> ordered = drafts.toList(
      growable: false,
    );
    if (ordered.isEmpty) return const <TodoRow>[];
    await ensureColumns();
    return _db.transaction(() async {
      final List<TodoColumnRow> columns = await listColumns();
      if (!columns.any((TodoColumnRow column) => column.id == columnId)) {
        throw StateError('Column is not live: $columnId');
      }
      int boardOrder = await _nextBoardOrder(columnId);
      final String timestamp = _stamp();
      final List<TodoRow> created = <TodoRow>[];
      for (final ({String text, String sourceRef}) draft in ordered) {
        final String id = _idFactory();
        await _db
            .into(_db.todos)
            .insert(
              TodosCompanion.insert(
                id: id,
                body: draft.text,
                createdAt: timestamp,
                updatedAt: timestamp,
                sourceRef: Value(draft.sourceRef),
                columnId: Value(columnId),
                boardOrder: Value(boardOrder++),
                syncDirty: const Value(true),
              ),
            );
        created.add((await _db.getTodoRow(id))!);
      }
      return List<TodoRow>.unmodifiable(created);
    });
  }

  /// Stamps the LOCAL-ONLY capture fingerprint on every voice row of
  /// [sourceRef] (live or soft-deleted). Deliberately NOT through [_write]:
  /// the column never syncs, so bumping `updated_at` or dirtying the rows would
  /// push a no-op edit to every peer. Manual provenance is left untouched.
  Future<void> setCaptureFingerprint(
    String sourceRef,
    String fingerprint,
  ) async {
    await (_db.update(_db.todos)..where(
          (t) =>
              t.source.equals(_voiceTodoSource) & t.sourceRef.equals(sourceRef),
        ))
        .write(TodosCompanion(captureFingerprint: Value(fingerprint)));
  }

  /// Soft-deletes every live voice todo captured from [sourceRef] (the card's
  /// Undo). Manual cards retaining the ref survive. Voice rows stay as
  /// tombstoned provenance, so [hasTodosFromSource] keeps answering true and
  /// detection never re-fires for that dump.
  Future<int> softDeleteFromSource(String sourceRef) async {
    // A one-shot .get(), not the watch stream's .first: awaiting a stream
    // inside a widget-test pump serialises badly and the card never redrew.
    final List<TodoRow> rows =
        await (_db.select(_db.todos)..where(
              (t) =>
                  t.source.equals(_voiceTodoSource) &
                  t.sourceRef.equals(sourceRef) &
                  t.deletedAt.isNull(),
            ))
            .get();
    for (final TodoRow row in rows) {
      await softDelete(row.id);
    }
    return rows.length;
  }

  /// Checks an open item (stamps `done_at`) or unchecks a done one
  /// (clears it). Completing a card files it at the end of the rightmost live
  /// Kanban column; unchecking never moves it back.
  Future<void> toggle(String id) async {
    final List<TodoColumnRow> columns = await ensureColumns();
    await _db.transaction(() async {
      final TodoRow? row = await _db.getTodoRow(id);
      if (row == null) return;
      if (row.doneAt != null) {
        await _write(id, const TodosCompanion(doneAt: Value(null)));
        return;
      }
      await _write(id, TodosCompanion(doneAt: Value(_stamp())));
      final String lastColumnId = columns.last.id;
      if (row.columnId != lastColumnId) {
        await moveOnBoard(id, lastColumnId, 1 << 30);
      }
    });
  }

  /// Appends selected cards to [columnId] in the iteration order of [ids].
  /// Source lanes are compacted and every moved card spends its migration
  /// marker in this transaction, exactly like a single explicit board move.
  Future<void> moveManyOnBoard(Iterable<String> ids, String columnId) async {
    final List<String> orderedIds = ids.toSet().toList(growable: false);
    if (orderedIds.isEmpty) return;
    await _db.transaction(() async {
      final List<TodoColumnRow> columns = await listColumns();
      if (!columns.any((column) => column.id == columnId)) {
        throw StateError('Column is not live: $columnId');
      }
      final List<TodoRow> moving = <TodoRow>[];
      for (final String id in orderedIds) {
        final TodoRow? row = await _db.getTodoRow(id);
        if (row == null || row.deletedAt != null || row.columnId == columnId) {
          continue;
        }
        moving.add(row);
      }
      if (moving.isEmpty) return;

      final Set<String> sourceIds = moving
          .map((row) => row.columnId)
          .whereType<String>()
          .toSet();
      int order = await _nextBoardOrder(columnId);
      for (final TodoRow row in moving) {
        await _writeBoardPlacement(
          row.id,
          TodosCompanion(columnId: Value(columnId), boardOrder: Value(order++)),
        );
      }
      for (final String sourceId in sourceIds) {
        final List<TodoRow> remaining =
            await (_db.select(_db.todos)
                  ..where(
                    (t) => t.columnId.equals(sourceId) & t.deletedAt.isNull(),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.boardOrder)]))
                .get();
        for (int i = 0; i < remaining.length; i++) {
          if (remaining[i].boardOrder == i) continue;
          await _writeBoardPlacement(
            remaining[i].id,
            TodosCompanion(boardOrder: Value(i)),
          );
        }
      }
    });
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
          await _writeBoardPlacement(
            lane[i].id,
            TodosCompanion(columnId: Value(laneId), boardOrder: Value(i)),
          );
        }
      }
      // Even a drop back onto the same slot is an explicit placement. Spend
      // the migration marker atomically so a legacy null/absent sync echo can
      // never reinterpret this user's choice as migration-only dirt.
      await _db.completeTodoBoardBackfill(todoId);
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
        // Choosing a destination in the delete-column sheet is also an
        // explicit placement, not migration fallback.
        await _writeBoardPlacement(
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
  /// unlike [toggle]). Live board cards are appended to the rightmost live
  /// column in [ids] iteration order; rows without a live board placement keep
  /// their placement. Completion and every board move share one transaction.
  Future<void> markManyDone(Iterable<String> ids) async {
    final List<String> orderedIds = ids.toSet().toList(growable: false);
    if (orderedIds.isEmpty) return;
    await _db.transaction(() async {
      final List<TodoColumnRow> columns = await listColumns();
      final Set<String> liveColumnIds = columns
          .map((TodoColumnRow column) => column.id)
          .toSet();
      final String? lastColumnId = columns.isEmpty ? null : columns.last.id;
      for (final String id in orderedIds) {
        final TodoRow? row = await _db.getTodoRow(id);
        if (row == null || row.doneAt != null) continue;
        await _write(id, TodosCompanion(doneAt: Value(_stamp())));
        if (lastColumnId != null && liveColumnIds.contains(row.columnId)) {
          await moveOnBoard(id, lastColumnId, 1 << 30);
        }
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

  /// Persists a user-authored board position and retires any one-shot
  /// migration marker. Callers wrap multi-row operations in a transaction so
  /// the placement and marker deletion commit or roll back together.
  Future<void> _writeBoardPlacement(String id, TodosCompanion changes) async {
    await _write(id, changes);
    await _db.completeTodoBoardBackfill(id);
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

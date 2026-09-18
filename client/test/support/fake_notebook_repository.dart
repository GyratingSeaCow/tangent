// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/native.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';

/// In-memory [NotebookRepository] for widget tests.
///
/// Every public method is overridden, so the database handed to `super` is
/// never queried — it exists only to satisfy the constructor, and a single
/// lazily built instance is shared so drift never warns about the same
/// executor being wrapped twice. Tests assert on [saved], [deleted] and
/// [createCalls] instead of reading SQLite.
class FakeNotebookRepository extends NotebookRepository {
  FakeNotebookRepository({List<Notebook> seed = const <Notebook>[]})
      : super(db: _unusedDb) {
    for (final Notebook notebook in seed) {
      _notebooks[notebook.id] = notebook;
    }
  }

  static final LocalDb _unusedDb =
      LocalDb.forTesting(NativeDatabase.memory());

  final Map<String, Notebook> _notebooks = <String, Notebook>{};
  final StreamController<List<Notebook>> _changes =
      StreamController<List<Notebook>>.broadcast();

  /// Every notebook handed to [saveNotebook], in call order.
  final List<Notebook> saved = <Notebook>[];

  /// Every id handed to [deleteNotebook], in call order.
  final List<String> deleted = <String>[];

  int createCalls = 0;
  DateTime now = DateTime.utc(2026, 9, 17, 12);
  int _ids = 0;

  /// Current rows, newest-updated first (the order the real repository uses).
  List<Notebook> get snapshot {
    final List<Notebook> rows = _notebooks.values.toList()
      ..sort((Notebook a, Notebook b) => b.updatedAt.compareTo(a.updatedAt));
    return List<Notebook>.unmodifiable(rows);
  }

  void dispose() => unawaited(_changes.close());

  @override
  Stream<List<Notebook>> watchNotebooks() async* {
    yield snapshot;
    yield* _changes.stream;
  }

  @override
  Future<Notebook?> getNotebook(String id) async => _notebooks[id];

  @override
  Future<Notebook> createNotebook({String? title}) async {
    createCalls += 1;
    final Notebook notebook = Notebook(
      id: 'notebook-${++_ids}',
      title: title ?? defaultNotebookTitle(now),
      createdAt: now,
      updatedAt: now,
      document: const NotebookDocument.empty(),
      ink: const NotebookInk.empty(),
    );
    _notebooks[notebook.id] = notebook;
    _emit();
    return notebook;
  }

  @override
  Future<void> saveNotebook(Notebook notebook) async {
    saved.add(notebook);
    _notebooks[notebook.id] = notebook;
    _emit();
  }

  @override
  Future<void> deleteNotebook(String id) async {
    deleted.add(id);
    _notebooks.remove(id);
    _emit();
  }

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(snapshot);
  }
}

/// Convenience builder for a fully formed [Notebook] fixture.
Notebook testNotebook({
  String id = 'nb-1',
  String title = 'Ideas',
  List<NotebookBlock> blocks = const <NotebookBlock>[],
  List<InkStroke> strokes = const <InkStroke>[],
  DateTime? updatedAt,
  String? folderId,
}) {
  final DateTime at = updatedAt ?? DateTime.utc(2026, 9, 17, 12);
  return Notebook(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    document: NotebookDocument(blocks),
    ink: NotebookInk(strokes),
    folderId: folderId,
  );
}

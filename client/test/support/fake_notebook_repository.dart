// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/models/notebook_ruling.dart';
import 'package:tangent/services/notebook_password.dart';

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

  static final LocalDb _unusedDb = LocalDb.forTesting(NativeDatabase.memory());

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

  /// Headers derived from the same rows [watchNotebooks] serves, so widget
  /// tests seeding full notebooks exercise the header-driven list unchanged.
  @override
  Stream<List<NotebookListEntry>> watchNotebookHeaders() {
    List<NotebookListEntry> headers(List<Notebook> rows) => rows
        .map(
          (Notebook n) => NotebookListEntry(
            id: n.id,
            title: n.title,
            updatedAt: n.updatedAt,
            folderId: n.folderId,
            pinned: n.pinned,
            passwordHash: n.passwordHash,
          ),
        )
        .toList(growable: false);
    return watchNotebooks().map(headers);
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

  @override
  Future<void> setPinned(String id, bool pinned) async {
    final Notebook? notebook = _notebooks[id];
    if (notebook == null) return;
    _notebooks[id] = Notebook(
      id: notebook.id,
      title: notebook.title,
      createdAt: notebook.createdAt,
      updatedAt: notebook.updatedAt,
      document: notebook.document,
      ink: notebook.ink,
      folderId: notebook.folderId,
      pinned: pinned,
      ruling: notebook.ruling,
      lastPenStyle: notebook.lastPenStyle,
      passwordHash: notebook.passwordHash,
      passwordSalt: notebook.passwordSalt,
      passwordIterations: notebook.passwordIterations,
    );
    _emit();
  }

  @override
  Future<void> setPassword(String id, String password) async {
    final Notebook? notebook = _notebooks[id];
    if (notebook == null) throw StateError('Notebook is no longer available');
    final NotebookPasswordMetadata metadata =
        fakeNotebookPasswordMetadata(password);
    _notebooks[id] = Notebook(
      id: notebook.id,
      title: notebook.title,
      createdAt: notebook.createdAt,
      updatedAt: notebook.updatedAt,
      document: notebook.document,
      ink: notebook.ink,
      folderId: notebook.folderId,
      pinned: notebook.pinned,
      ruling: notebook.ruling,
      lastPenStyle: notebook.lastPenStyle,
      passwordHash: metadata.hash,
      passwordSalt: metadata.salt,
      passwordIterations: metadata.iterations,
    );
    _emit();
  }

  @override
  Future<bool> verifyPassword(String id, String password) async {
    final Notebook? notebook = _notebooks[id];
    if (notebook?.passwordHash == null ||
        notebook?.passwordSalt == null ||
        notebook?.passwordIterations == null) {
      return false;
    }
    if (notebook!.passwordSalt == _fakePasswordSalt) {
      return notebook.passwordHash == fakeNotebookPasswordMetadata(password).hash;
    }
    return verifyNotebookPassword(
      password: password,
      hash: notebook.passwordHash!,
      salt: notebook.passwordSalt!,
      iterations: notebook.passwordIterations!,
    );
  }

  @override
  Future<bool> removePassword(String id, String password) async {
    if (!await verifyPassword(id, password)) return false;
    final Notebook notebook = _notebooks[id]!;
    _notebooks[id] = Notebook(
      id: notebook.id,
      title: notebook.title,
      createdAt: notebook.createdAt,
      updatedAt: notebook.updatedAt,
      document: notebook.document,
      ink: notebook.ink,
      folderId: notebook.folderId,
      pinned: notebook.pinned,
      ruling: notebook.ruling,
      lastPenStyle: notebook.lastPenStyle,
    );
    _emit();
    return true;
  }

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(snapshot);
  }
}

final String _fakePasswordSalt = base64Encode(utf8.encode('widget-test-salt'));

/// Fast deterministic verifier used only by widget fakes. Production tests
/// exercise PBKDF2 through the real repository; widget tests must not leave a
/// background isolate behind Flutter's fake-async boundary.
NotebookPasswordMetadata fakeNotebookPasswordMetadata(String password) =>
    NotebookPasswordMetadata(
      hash: base64Encode(
        sha256.convert(utf8.encode('widget-test-salt:$password')).bytes,
      ),
      salt: _fakePasswordSalt,
      iterations: 100000,
    );

/// Convenience builder for a fully formed [Notebook] fixture.
Notebook testNotebook({
  String id = 'nb-1',
  String title = 'Ideas',
  List<NotebookBlock> blocks = const <NotebookBlock>[],
  List<InkStroke> strokes = const <InkStroke>[],
  DateTime? updatedAt,
  String? folderId,
  bool pinned = false,
  NotebookRuling ruling = NotebookRuling.medium,
  String? passwordHash,
  String? passwordSalt,
  int? passwordIterations,
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
    pinned: pinned,
    ruling: ruling,
    passwordHash: passwordHash,
    passwordSalt: passwordSalt,
    passwordIterations: passwordIterations,
  );
}

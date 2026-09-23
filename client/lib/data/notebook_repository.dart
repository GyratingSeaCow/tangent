// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/notebook.dart';
import '../models/notebook_ruling.dart';
import '../screens/home/home_screen.dart' show localDbProvider;
import 'local_db.dart';

/// Local persistence for notebooks (phase 1: on-device only, never synced).
///
/// Every save writes the whole document and ink layer in one row update, so a
/// notebook is never observed half-written.
class NotebookRepository {
  NotebookRepository({
    required LocalDb db,
    String Function()? idFactory,
    DateTime Function()? now,
  })  : _db = db,
        _idFactory = idFactory ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now;

  final LocalDb _db;
  final String Function() _idFactory;
  final DateTime Function() _now;

  /// Most recently edited first, so the list reorders as the user works.
  /// Trashed notebooks stay out; they live under Settings → Trash.
  Stream<List<Notebook>> watchNotebooks() => (_db.select(_db.notebooks)
        ..where((n) => n.deletedAt.isNull())
        ..orderBy([(n) => OrderingTerm.desc(n.updatedAt)]))
      .watch()
      .map((rows) => rows.map(_fromRow).toList(growable: false));

  Future<Notebook?> getNotebook(String id) async {
    // Trashed rows read as absent: to the live app a trashed notebook is
    // gone, and only Settings → Trash can see it. Without this filter the
    // editor could reopen (and re-save) a notebook the user just deleted.
    final row = await (_db.select(_db.notebooks)
          ..where((n) => n.id.equals(id) & n.deletedAt.isNull()))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<Notebook> createNotebook({String? title}) async {
    final timestamp = _now();
    final notebook = Notebook(
      id: _idFactory(),
      title: title ?? defaultNotebookTitle(timestamp),
      createdAt: timestamp,
      updatedAt: timestamp,
      document: const NotebookDocument.empty(),
      ink: const NotebookInk.empty(),
      // New notebooks arrive ruled; the model's default states which.
    );
    await _db.into(_db.notebooks).insert(
          NotebooksCompanion.insert(
            id: notebook.id,
            title: notebook.title,
            createdAt: timestamp.millisecondsSinceEpoch,
            updatedAt: timestamp.millisecondsSinceEpoch,
            docJson: notebook.document.encode(),
            inkJson: notebook.ink.encode(),
            ruling: Value<String?>(notebook.ruling.wireValue),
          ),
        );
    return notebook;
  }

  /// Overwrites the row and stamps a fresh `updated_at`. `created_at` is
  /// immutable; unknown block kinds ride through untouched inside [doc_json].
  Future<void> saveNotebook(Notebook notebook) async {
    final timestamp = _now();
    await (_db.update(_db.notebooks)..where((n) => n.id.equals(notebook.id)))
        .write(
      NotebooksCompanion(
        title: Value(notebook.title),
        updatedAt: Value(timestamp.millisecondsSinceEpoch),
        docJson: Value(notebook.document.encode()),
        inkJson: Value(notebook.ink.encode()),
        // Ruling and nib travel with every ordinary save. Ruling's absence
        // here was a latent bug: cycling the ruling then reopening lost the
        // choice because this UPDATE never wrote the column.
        ruling: Value<String?>(notebook.ruling.wireValue),
        lastPenStyle: Value<String?>(notebook.lastPenStyle?.wireValue),
        // Every local edit is unsynced work until the server confirms it.
        // Marked here, in the one place ordinary edits funnel through, rather
        // than at each call site — a save that forgot this flag would be
        // invisible to the user's other devices with nothing to reveal it.
        syncDirty: const Value(true),
      ),
    );
  }

  /// Writes [notebook] verbatim, inserting or replacing the row and keeping
  /// the supplied timestamps instead of stamping `now`.
  ///
  /// Used by durable adoption, where the file's own `updated_at` decides the
  /// conflict and must survive intact; ordinary edits use [saveNotebook].
  Future<void> upsertNotebook(Notebook notebook) async {
    // Filing is local metadata and the published file carries no folder, so an
    // adopted notebook always arrives unfiled. Writing that straight through
    // would empty the user's folders one adoption at a time: file twenty
    // notebooks, let durable adoption re-import them, and the folder is bare.
    // Keep the existing filing unless the caller states one.
    final String? existingFolderId = notebook.folderId ??
        await (_db.selectOnly(_db.notebooks)
              ..addColumns([_db.notebooks.folderId])
              ..where(_db.notebooks.id.equals(notebook.id)))
            .map((row) => row.read(_db.notebooks.folderId))
            .getSingleOrNull();

    await _db.into(_db.notebooks).insertOnConflictUpdate(
          NotebooksCompanion.insert(
            id: notebook.id,
            title: notebook.title,
            createdAt: notebook.createdAt.millisecondsSinceEpoch,
            updatedAt: notebook.updatedAt.millisecondsSinceEpoch,
            docJson: notebook.document.encode(),
            inkJson: notebook.ink.encode(),
            folderId: Value<String?>(existingFolderId),
            ruling: Value<String?>(notebook.ruling.wireValue),
            lastPenStyle: Value<String?>(notebook.lastPenStyle?.wireValue),
          ),
        );
  }

  /// Deleting a notebook never touches the dumps its cards referenced.
  Future<void> deleteNotebook(String id) async {
    // Record the tombstone BEFORE the move. Trashing first would leave
    // nothing pushed, so the other device would never hear about the
    // deletion and would push the notebook straight back on its next sync.
    await _db.recordTombstone(entityType: 'notebook', entityId: id);
    // Trash, not delete (user decision): the row survives 7 days under
    // Settings → Trash so a deletion — local or synced-in — is reversible.
    await _db.trashNotebook(id);
  }

  Notebook _fromRow(NotebookRow row) => Notebook(
        id: row.id,
        title: row.title,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row.createdAt, isUtc: true),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row.updatedAt, isUtc: true),
        document: NotebookDocument.decode(row.docJson),
        ink: NotebookInk.decode(row.inkJson),
        folderId: row.folderId,
        // Null is a notebook written before ruling existed. It reads as blank,
        // NOT as the new-notebook default: an existing page must not silently
        // gain lines the user never asked for.
        ruling: NotebookRuling.parse(row.ruling),
        // Null is a notebook that has never recorded a nib: it opens with
        // the fountain default, chosen at the editor, not coerced here —
        // the model keeps the distinction between "never set" and "set".
        lastPenStyle: switch (row.lastPenStyle) {
          'fountain' => PenStyle.fountain,
          'ballpoint' => PenStyle.ballpoint,
          _ => null,
        },
      );
}

final notebookRepositoryProvider = Provider<NotebookRepository>(
  (ref) => NotebookRepository(db: ref.watch(localDbProvider)),
);

/// Live notebook list for the notebooks screen.
final notebooksProvider = StreamProvider<List<Notebook>>(
  (ref) => ref.watch(notebookRepositoryProvider).watchNotebooks(),
);

/// Live folder list for the notebooks screen.
///
/// A provider rather than a direct database read so the screen stays testable:
/// reaching for localDbProvider inside build() makes every widget test need a
/// real database, and the harness that only overrides notebooksProvider throws
/// 'Override in main()'.
final foldersProvider = StreamProvider<List<Folder>>(
  (ref) => ref.watch(localDbProvider).watchFolders(),
);

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notebook_repository.dart';
import '../data/storage/storage_codec.dart';
import '../data/storage/storage_contract.dart';
import '../data/storage/storage_providers.dart';
import '../models/notebook.dart';

/// Result of re-adopting durable notebook files from the selected folder.
typedef NotebookImportResult = ({
  List<String> adoptedIds,
  List<String> keptLocalIds,
  List<StorageProblem> problems
});

/// Current durable payload version. A file written by a newer build keeps its
/// own schema number; this build refuses to adopt what it cannot read rather
/// than coercing (and so destroying) a user's notebook.
const int notebookFileSchema = 1;

/// Encodes one notebook as its whole durable payload: a single self-contained
/// JSON object, no sidecar, timestamps as epoch milliseconds.
String encodeNotebookFile(Notebook notebook) => jsonEncode({
      'schema': notebookFileSchema,
      'id': notebook.id,
      'title': notebook.title,
      'createdAt': notebook.createdAt.millisecondsSinceEpoch,
      'updatedAt': notebook.updatedAt.millisecondsSinceEpoch,
      'doc': jsonDecode(notebook.document.encode()),
      'ink': jsonDecode(notebook.ink.encode()),
    });

/// Decodes a durable notebook payload.
///
/// Throws [StorageFault] with [ProblemCode.invalid] for anything this build
/// cannot read; the caller reports the problem and leaves the file alone.
/// Unknown block kinds inside `doc` are preserved verbatim by the model layer.
Notebook decodeNotebookFile(String source) {
  Never invalid(String message) =>
      throw StorageFault((code: ProblemCode.invalid, message: message));
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    invalid('Malformed notebook document');
  }
  if (decoded is! Map<String, dynamic>) {
    invalid('Notebook document is not an object');
  }
  if (decoded['schema'] != notebookFileSchema) {
    invalid('Unsupported notebook document schema');
  }
  final id = decoded['id'];
  final title = decoded['title'];
  final createdAt = decoded['createdAt'];
  final updatedAt = decoded['updatedAt'];
  final doc = decoded['doc'];
  final ink = decoded['ink'];
  if (id is! String ||
      title is! String ||
      createdAt is! int ||
      updatedAt is! int ||
      doc is! Map<String, dynamic> ||
      ink is! Map<String, dynamic>) {
    invalid('Notebook document fields are missing or mistyped');
  }
  StorageCodec.validateLiteralId(id);
  return Notebook(
    id: id,
    title: title,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    document: NotebookDocument.decode(jsonEncode(doc)),
    ink: NotebookInk.decode(jsonEncode(ink)),
  );
}

/// The durable filename for a notebook: `<id>.notebook.json`.
String notebookFileName(String id) {
  StorageCodec.validateLiteralId(id);
  return '$id$notebookFileSuffix';
}

/// Makes notebooks survive an uninstall.
///
/// Every notebook is published as ONE `<id>.notebook.json` inside the
/// 'Tangent Notebooks' child of the user's selected folder — a sibling of
/// 'Tangent Text Notes' — through the same storage backend text notes use.
/// The SQLite row stays the working copy; the file is the durable copy, and
/// folder import re-adopts files the database does not know about.
class NotebookPersistence {
  NotebookPersistence({
    required NotebookRepository repository,
    required StorageBackend backend,
    required StorageCatalog catalog,
  })  : _repository = repository,
        _backend = backend,
        _catalog = catalog;

  final NotebookRepository _repository;
  final StorageBackend _backend;
  final StorageCatalog _catalog;
  int _publications = 0;

  T _value<T>(Outcome<T> result) => switch (result) {
        Ok(:final value) => value,
        Fail(:final problem) => throw StorageFault(problem),
      };

  Future<T> _settled<T>(IoOperation<T> operation) async {
    try {
      return await operation.result;
    } finally {
      await operation.settled;
    }
  }

  /// The selected folder. An unavailable folder faults rather than silently
  /// skipping publication: a notebook the user believes is durable must not
  /// quietly exist only in the app database.
  Future<StorageLocation> _location() async {
    final state = await _catalog.watchDefault().first;
    if (!state.available || state.location == null) {
      throw StorageFault(
        state.problem ??
            (
              code: ProblemCode.unavailable,
              message: 'No default recording folder'
            ),
      );
    }
    return state.location!;
  }

  Future<DurableDocument> _publish(Notebook notebook) async {
    final location = await _location();
    return _value(
      await _settled(
        _backend.publishDocument(
          location,
          notebookSubdirectoryName,
          notebookFileName(notebook.id),
          encodeNotebookFile(notebook),
          'notebook-${notebook.id}-${_publications++}',
        ),
      ),
    );
  }

  /// Creates a notebook and publishes it immediately, so an uninstall right
  /// after creation still leaves the file behind.
  Future<Notebook> createNotebook({String? title}) async {
    final created = await _repository.createNotebook(title: title);
    await _publish(created);
    return created;
  }

  /// Saves the row FIRST and publishes afterwards.
  ///
  /// The database write is the durable-enough fallback: if publication fails
  /// the edit is still recoverable and the fault surfaces truthfully instead
  /// of being reported as a lost save. The previously published file is left
  /// untouched (the backend writes through a temporary and renames), so a
  /// failed publication never truncates the last good durable copy.
  Future<Notebook> saveNotebook(Notebook notebook) async {
    await _repository.saveNotebook(notebook);
    final saved = await _repository.getNotebook(notebook.id);
    if (saved == null) {
      throw StorageFault(
        (
          code: ProblemCode.absent,
          message: 'Notebook row disappeared during save'
        ),
      );
    }
    await _publish(saved);
    return saved;
  }

  /// Deletes the row and its durable file.
  ///
  /// The file is resolved by enumerating the owned child and taking the
  /// provider-issued locator of the exact matching document. Document IDs are
  /// opaque and are NEVER parsed as paths.
  Future<ComponentResult> deleteNotebook(String id) async {
    final name = notebookFileName(id);
    final location = await _location();
    final documents = _value(
      await _settled(
        _backend.listDocuments(
          location,
          notebookSubdirectoryName,
          notebookFileSuffix,
        ),
      ),
    ).where((document) => document.name == name).toList();
    await _repository.deleteNotebook(id);
    if (documents.isEmpty) {
      return (state: ComponentState.absent, problem: null);
    }
    if (documents.length != 1) {
      return (
        state: ComponentState.failed,
        problem: (
          code: ProblemCode.conflict,
          message: 'Ambiguous durable notebook document'
        )
      );
    }
    return _settled(
      _backend.deleteDocument(
        location,
        notebookSubdirectoryName,
        name,
        documents.single.locator,
        'notebook-delete-$id',
      ),
    );
  }

  /// Re-adopts durable notebook files into the database.
  ///
  /// The file's `id` is the durable identity. The copy with the NEWER
  /// `updatedAt` wins; equal timestamps keep the local row. A file this build
  /// cannot read is reported and skipped. No user file is ever deleted here.
  Future<NotebookImportResult> importNotebooks() async {
    final adopted = <String>[];
    final keptLocal = <String>[];
    final problems = <StorageProblem>[];
    List<DurableDocument> documents;
    try {
      documents = _value(
        await _settled(
          _backend.listDocuments(
            await _location(),
            notebookSubdirectoryName,
            notebookFileSuffix,
          ),
        ),
      );
    } on StorageFault catch (e) {
      return (adoptedIds: adopted, keptLocalIds: keptLocal, problems: [
        e.problem,
      ]);
    }
    for (final document in documents) {
      try {
        final notebook = decodeNotebookFile(document.content);
        if (document.name != notebookFileName(notebook.id)) {
          throw const StorageFault(
            (
              code: ProblemCode.invalid,
              message: 'Notebook document name and identity differ'
            ),
          );
        }
        final existing = await _repository.getNotebook(notebook.id);
        if (existing != null &&
            !notebook.updatedAt.isAfter(existing.updatedAt)) {
          keptLocal.add(notebook.id);
          continue;
        }
        await _repository.upsertNotebook(notebook);
        adopted.add(notebook.id);
      } on StorageFault catch (e) {
        problems.add(e.problem);
      }
    }
    return (
      adoptedIds: adopted,
      keptLocalIds: keptLocal,
      problems: problems
    );
  }
}

final notebookPersistenceProvider = Provider<NotebookPersistence>(
  (ref) => NotebookPersistence(
    repository: ref.watch(notebookRepositoryProvider),
    backend: ref.watch(storageBackendProvider),
    catalog: ref.watch(storageCatalogProvider),
  ),
);

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as image_lib;
import 'package:uuid/uuid.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart';
import '../../models/notebook.dart';
import '../../screens/home/home_screen.dart' show localDbProvider;
import '../notebook_import.dart';
import 'note_import_model.dart';

class NoteImportCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

enum NoteImportResultKind { imported, skipped }

class NoteImportResultEntry {
  const NoteImportResultEntry({
    required this.kind,
    required this.sourceName,
    required this.message,
    this.notebookTitle,
  });

  final NoteImportResultKind kind;
  final String sourceName;
  final String message;
  final String? notebookTitle;
}

class NoteImportReport {
  const NoteImportReport({required this.entries, required this.cancelled});
  final List<NoteImportResultEntry> entries;
  final bool cancelled;
  int get imported =>
      entries.where((e) => e.kind == NoteImportResultKind.imported).length;
  int get skipped =>
      entries.where((e) => e.kind == NoteImportResultKind.skipped).length;
}

abstract interface class NoteImportStore {
  Future<Set<String>> loadNotebookTitles();
  Future<Map<String, String>> loadFoldersByName();
  Future<String> createFolder(String name);
  Future<void> saveNotebook(Notebook notebook);
}

class LocalNoteImportStore implements NoteImportStore {
  LocalNoteImportStore({
    required NotebookRepository notebooks,
    required LocalDb db,
  }) : _notebooks = notebooks,
       _db = db;

  final NotebookRepository _notebooks;
  final LocalDb _db;

  @override
  Future<Set<String>> loadNotebookTitles() async =>
      (await _notebooks.watchNotebookHeaders().first)
          .map((row) => row.title)
          .toSet();

  @override
  Future<Map<String, String>> loadFoldersByName() async => <String, String>{
    for (final Folder folder in await _db.watchFolders().first)
      folder.name: folder.id,
  };

  @override
  Future<String> createFolder(String name) => _db.createFolder(name: name);

  @override
  Future<void> saveNotebook(Notebook notebook) =>
      _notebooks.upsertNotebook(notebook);
}

class NoteImportService {
  NoteImportService({
    required NoteImportStore store,
    String Function()? idFactory,
    DateTime Function()? now,
  }) : _store = store,
       _idFactory = idFactory ?? const Uuid().v4,
       _now = now ?? DateTime.now;

  final NoteImportStore _store;
  final String Function() _idFactory;
  final DateTime Function() _now;

  Future<NoteImportReport> import({
    required NoteImportAdapter adapter,
    required NoteImportSource source,
    NoteImportCancellationToken? cancellationToken,
    void Function(NoteImportResultEntry entry)? onEntry,
  }) async {
    final NoteImportCancellationToken cancellation =
        cancellationToken ?? NoteImportCancellationToken();
    final Set<String> titles = await _store.loadNotebookTitles();
    final Map<String, String> folders = await _store.loadFoldersByName();
    final List<NoteImportResultEntry> report = <NoteImportResultEntry>[];

    void add(NoteImportResultEntry entry) {
      report.add(entry);
      onEntry?.call(entry);
    }

    try {
      await for (final NoteImportAdapterEvent event in adapter.read(source)) {
        if (cancellation.isCancelled) break;
        if (event is NoteImportSkipEvent) {
          add(
            NoteImportResultEntry(
              kind: NoteImportResultKind.skipped,
              sourceName: event.skip.sourceName,
              message: event.skip.reason,
            ),
          );
          continue;
        }
        final ImportedNote note = (event as NoteImportNoteEvent).note;
        try {
          final String title = uniqueNotebookTitle(note.title, titles);
          titles.add(title);
          String? folderId;
          final String? folderName = note.folderHint?.trim();
          if (folderName != null && folderName.isNotEmpty) {
            folderId = folders[folderName];
            if (folderId == null) {
              folderId = await _store.createFolder(folderName);
              folders[folderName] = folderId;
            }
          }
          final DateTime fallback = _now().toUtc();
          final DateTime createdAt =
              (note.createdAt ?? note.updatedAt ?? fallback).toUtc();
          final DateTime updatedAt =
              (note.updatedAt ?? note.createdAt ?? fallback).toUtc();
          final List<NotebookBlock> incoming = await _mapBlocks(note.blocks);
          final List<NotebookBlock> positioned = layoutImportedBlocks(
            existing: const <NotebookBlock>[],
            strokes: const <InkStroke>[],
            incoming: incoming,
            existingContentBottom: 0,
          );
          final Notebook notebook = Notebook(
            id: _idFactory(),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            document: NotebookDocument(positioned),
            ink: const NotebookInk.empty(),
            folderId: folderId,
          );
          await _store.saveNotebook(notebook);
          add(
            NoteImportResultEntry(
              kind: NoteImportResultKind.imported,
              sourceName: note.sourceName,
              notebookTitle: title,
              message: folderName == null || folderName.isEmpty
                  ? 'Imported as $title'
                  : 'Imported as $title in $folderName',
            ),
          );
        } catch (error) {
          add(
            NoteImportResultEntry(
              kind: NoteImportResultKind.skipped,
              sourceName: note.sourceName,
              message: 'Could not import note: $error',
            ),
          );
        }
      }
    } catch (error) {
      add(
        NoteImportResultEntry(
          kind: NoteImportResultKind.skipped,
          sourceName: source.displayName,
          message: 'Import stopped: $error',
        ),
      );
    }
    return NoteImportReport(
      entries: List<NoteImportResultEntry>.unmodifiable(report),
      cancelled: cancellation.isCancelled,
    );
  }

  Future<List<NotebookBlock>> _mapBlocks(List<ImportedNoteBlock> source) async {
    final List<NotebookBlock> blocks = <NotebookBlock>[];
    for (final ImportedNoteBlock block in source) {
      switch (block) {
        case ImportedText(:final text):
          if (text.trim().isNotEmpty) {
            blocks.add(NotebookTextBlock(id: _idFactory(), text: text));
          }
        case ImportedChecklistItem(:final text, :final checked):
          blocks.add(
            NotebookCheckboxBlock(
              id: _idFactory(),
              text: text,
              checked: checked,
            ),
          );
        case ImportedAttachmentProblem(:final message):
          blocks.add(NotebookTextBlock(id: _idFactory(), text: '[$message]'));
        case ImportedImage(:final bytes, :final mime, :final name):
          final _PreparedImage? prepared = await Isolate.run(
            () => _prepareImportedImage(bytes, mime),
          );
          if (prepared == null) {
            blocks.add(
              NotebookTextBlock(
                id: _idFactory(),
                text: '[Attachment skipped: $name could not be decoded]',
              ),
            );
            continue;
          }
          const double maxWidth = 640;
          final double width = prepared.width > maxWidth
              ? maxWidth
              : prepared.width.toDouble();
          final double height = prepared.height * (width / prepared.width);
          blocks.add(
            NotebookImageBlock(
              id: _idFactory(),
              data: base64Encode(prepared.bytes),
              mime: prepared.mime,
              x: 0,
              y: 0,
              width: width,
              height: height,
            ),
          );
      }
    }
    if (blocks.isEmpty) {
      blocks.add(NotebookTextBlock(id: _idFactory(), text: '(empty note)'));
    }
    return blocks;
  }
}

const int maxImportedImageEdge = 2048;

class _PreparedImage {
  const _PreparedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
}

_PreparedImage? _prepareImportedImage(Uint8List bytes, String mime) {
  final image_lib.Image? decoded = image_lib.decodeImage(bytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) return null;

  final bool hasOrientation =
      decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1;
  image_lib.Image image = hasOrientation
      ? image_lib.bakeOrientation(decoded)
      : decoded;
  final bool oversized =
      image.width > maxImportedImageEdge || image.height > maxImportedImageEdge;
  if (!hasOrientation && !oversized) {
    return _PreparedImage(
      bytes: bytes,
      mime: mime,
      width: image.width,
      height: image.height,
    );
  }

  if (oversized) {
    if (image.width >= image.height) {
      image = image_lib.copyResize(image, width: maxImportedImageEdge);
    } else {
      image = image_lib.copyResize(image, height: maxImportedImageEdge);
    }
  }
  final (Uint8List encoded, String encodedMime) = switch (mime.toLowerCase()) {
    'image/jpeg' ||
    'image/jpg' => (image_lib.encodeJpg(image, quality: 90), 'image/jpeg'),
    'image/gif' => (image_lib.encodeGif(image), 'image/gif'),
    'image/webp' => (image_lib.encodeWebP(image), 'image/webp'),
    'image/bmp' => (image_lib.encodeBmp(image), 'image/bmp'),
    _ => (image_lib.encodePng(image), 'image/png'),
  };
  return _PreparedImage(
    bytes: encoded,
    mime: encodedMime,
    width: image.width,
    height: image.height,
  );
}

String uniqueNotebookTitle(String requested, Set<String> used) {
  final String base = requested.trim().isEmpty
      ? 'Untitled note'
      : requested.trim();
  if (!used.contains(base)) return base;
  int suffix = 2;
  while (used.contains('$base ($suffix)')) {
    suffix++;
  }
  return '$base ($suffix)';
}

final noteImportStoreProvider = Provider<NoteImportStore>(
  (ref) => LocalNoteImportStore(
    notebooks: ref.watch(notebookRepositoryProvider),
    db: ref.watch(localDbProvider),
  ),
);

final noteImportServiceProvider = Provider<NoteImportService>(
  (ref) => NoteImportService(store: ref.watch(noteImportStoreProvider)),
);

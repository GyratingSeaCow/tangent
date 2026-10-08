// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

/// Source-neutral note representation used by every one-shot importer.
///
/// Adapters only decode their own format into this model. The import service is
/// the single place that creates Tangent folders, de-duplicates titles and maps
/// these blocks to notebook blocks.
class ImportedNote {
  const ImportedNote({
    required this.sourceName,
    required this.title,
    required this.blocks,
    this.createdAt,
    this.updatedAt,
    this.folderHint,
  });

  final String sourceName;
  final String title;
  final List<ImportedNoteBlock> blocks;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// A source hierarchy hint. Tangent folders are flat, so nested source paths
  /// are retained as a single `Parent / Child` folder name.
  final String? folderHint;
}

sealed class ImportedNoteBlock {
  const ImportedNoteBlock();
}

class ImportedText extends ImportedNoteBlock {
  const ImportedText(this.text);
  final String text;
}

class ImportedChecklistItem extends ImportedNoteBlock {
  const ImportedChecklistItem(this.text, {required this.checked});
  final String text;
  final bool checked;
}

class ImportedImage extends ImportedNoteBlock {
  const ImportedImage({
    required this.name,
    required this.bytes,
    required this.mime,
  });

  final String name;
  final Uint8List bytes;
  final String mime;
}

/// Explicitly visible fallback for an attachment that could not be imported.
class ImportedAttachmentProblem extends ImportedNoteBlock {
  const ImportedAttachmentProblem(this.message);
  final String message;
}

class NoteImportSkip {
  const NoteImportSkip({required this.sourceName, required this.reason});
  final String sourceName;
  final String reason;
}

sealed class NoteImportAdapterEvent {
  const NoteImportAdapterEvent();
}

class NoteImportNoteEvent extends NoteImportAdapterEvent {
  const NoteImportNoteEvent(this.note);
  final ImportedNote note;
}

class NoteImportSkipEvent extends NoteImportAdapterEvent {
  const NoteImportSkipEvent(this.skip);
  final NoteImportSkip skip;
}

abstract interface class NoteImportAdapter {
  Stream<NoteImportAdapterEvent> read(NoteImportSource source);
}

/// Read-only view of either a directory, archive, or selected file.
abstract interface class NoteImportSource {
  String get displayName;
  Stream<NoteImportEntry> entries();
  Future<NoteImportEntry?> find(String relativePath);
}

class NoteImportEntry {
  const NoteImportEntry({
    required this.path,
    required this.size,
    required this.readBytes,
    this.modifiedAt,
  });

  /// Slash-separated relative path, never absolute and never containing `..`.
  final String path;
  final int size;
  final Future<Uint8List> Function() readBytes;
  final DateTime? modifiedAt;

  String get name => path.split('/').last;
}

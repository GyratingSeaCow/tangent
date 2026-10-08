// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'note_import_model.dart';

class GoogleKeepAdapter implements NoteImportAdapter {
  const GoogleKeepAdapter();

  @override
  Stream<NoteImportAdapterEvent> read(NoteImportSource source) async* {
    final List<NoteImportEntry> entries = await source.entries().toList();
    final Map<String, NoteImportEntry> byPath = <String, NoteImportEntry>{
      for (final NoteImportEntry entry in entries) entry.path: entry,
    };
    int candidates = 0;
    for (final NoteImportEntry entry in entries) {
      if (!entry.path.toLowerCase().endsWith('.json')) continue;
      candidates++;
      try {
        final Object? decoded = jsonDecode(
          utf8.decode(await entry.readBytes(), allowMalformed: true),
        );
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('JSON root is not an object');
        }
        if (decoded['isTrashed'] == true) {
          yield NoteImportSkipEvent(
            NoteImportSkip(
              sourceName: entry.path,
              reason: 'Note is in Google Keep trash',
            ),
          );
          continue;
        }
        if (!decoded.containsKey('title') &&
            !decoded.containsKey('textContent') &&
            !decoded.containsKey('listContent')) {
          yield NoteImportSkipEvent(
            NoteImportSkip(
              sourceName: entry.path,
              reason: 'Not a Google Keep note JSON file',
            ),
          );
          continue;
        }
        yield NoteImportNoteEvent(await _decode(entry, decoded, byPath));
      } catch (error) {
        yield NoteImportSkipEvent(
          NoteImportSkip(
            sourceName: entry.path,
            reason: 'Unreadable Keep note: $error',
          ),
        );
      }
    }
    if (candidates == 0) {
      yield NoteImportSkipEvent(
        NoteImportSkip(
          sourceName: source.displayName,
          reason: 'No Google Keep JSON notes found',
        ),
      );
    }
  }

  Future<ImportedNote> _decode(
    NoteImportEntry entry,
    Map<String, dynamic> raw,
    Map<String, NoteImportEntry> byPath,
  ) async {
    final List<ImportedNoteBlock> blocks = <ImportedNoteBlock>[];
    final Object? text = raw['textContent'];
    if (text is String && text.trim().isNotEmpty) {
      for (final String paragraph in text.split(RegExp(r'\r?\n\s*\r?\n'))) {
        if (paragraph.trim().isNotEmpty) {
          blocks.add(ImportedText(paragraph.trim()));
        }
      }
    }
    final Object? list = raw['listContent'];
    if (list is List) {
      for (final Object? item in list) {
        if (item is! Map) continue;
        final Object? itemText = item['text'];
        if (itemText is! String || itemText.trim().isEmpty) continue;
        blocks.add(
          ImportedChecklistItem(
            itemText.trim(),
            checked: item['isChecked'] == true,
          ),
        );
      }
    }

    final List<String> labels = <String>[];
    final Object? rawLabels = raw['labels'];
    if (rawLabels is List) {
      for (final Object? label in rawLabels) {
        final Object? name = label is Map ? label['name'] : null;
        if (name is String && name.trim().isNotEmpty) labels.add(name.trim());
      }
    }
    labels.sort();
    if (labels.length > 1) {
      blocks.add(ImportedText('Google Keep labels: ${labels.join(', ')}'));
    }

    final String directory = p.posix.dirname(entry.path) == '.'
        ? ''
        : p.posix.dirname(entry.path);
    final Object? attachments = raw['attachments'];
    if (attachments is List) {
      for (final Object? attachment in attachments) {
        final Object? filePath = attachment is Map
            ? attachment['filePath']
            : null;
        if (filePath is! String || filePath.trim().isEmpty) {
          blocks.add(
            const ImportedAttachmentProblem(
              'Attachment skipped: missing file path',
            ),
          );
          continue;
        }
        final String? relative = _resolveAttachment(directory, filePath);
        NoteImportEntry? asset = relative == null ? null : byPath[relative];
        if (asset == null && relative != null) {
          final String extension = p.posix.extension(relative).toLowerCase();
          final String? siblingExtension = switch (extension) {
            '.jpg' => '.jpeg',
            '.jpeg' => '.jpg',
            _ => null,
          };
          if (siblingExtension != null) {
            asset =
                byPath['${relative.substring(0, relative.length - extension.length)}$siblingExtension'];
          }
        }
        final String? mime =
            attachment is Map && attachment['mimetype'] is String
            ? attachment['mimetype'] as String
            : _mimeFor(filePath);
        if (asset == null || mime == null || !mime.startsWith('image/')) {
          blocks.add(
            ImportedAttachmentProblem('Attachment skipped: $filePath'),
          );
          continue;
        }
        blocks.add(
          ImportedImage(
            name: asset.name,
            bytes: await asset.readBytes(),
            mime: mime,
          ),
        );
      }
    }
    if (blocks.isEmpty) blocks.add(const ImportedText('(empty note)'));

    final String rawTitle = raw['title'] is String
        ? raw['title'] as String
        : '';
    final String title = rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : _fallbackTitle(blocks, entry.name);
    final DateTime? updatedAt = _keepTimestamp(raw['userEditedTimestampUsec']);
    final DateTime? createdAt = _keepTimestamp(raw['createdTimestampUsec']);
    return ImportedNote(
      sourceName: entry.path,
      title: title,
      folderHint: labels.isEmpty
          ? 'Google Keep'
          : 'Google Keep / ${labels.first}',
      createdAt: createdAt ?? updatedAt,
      updatedAt: updatedAt,
      blocks: blocks,
    );
  }
}

String _fallbackTitle(List<ImportedNoteBlock> blocks, String fileName) {
  for (final ImportedNoteBlock block in blocks) {
    final String? text = switch (block) {
      ImportedText(:final text) => text,
      ImportedChecklistItem(:final text) => text,
      _ => null,
    };
    if (text != null && text.trim().isNotEmpty) {
      final String first = text.trim().split('\n').first;
      return first.length <= 80 ? first : '${first.substring(0, 77)}…';
    }
  }
  final String base = p.basenameWithoutExtension(fileName).trim();
  return base.isEmpty ? 'Untitled Keep note' : base;
}

String? _resolveAttachment(String directory, String input) {
  final String slashed = input.replaceAll('\\', '/');
  if (slashed.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(slashed)) {
    return null;
  }
  final List<String> parts = directory.isEmpty
      ? <String>[]
      : directory.split('/').where((part) => part.isNotEmpty).toList();
  final int floor = parts.length;
  for (final String part in slashed.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.length == floor) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

DateTime? _keepTimestamp(Object? micros) {
  final int? value = switch (micros) {
    num n => n.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
  if (value == null || value < 0) return null;
  return DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
}

String? _mimeFor(String name) => switch (p.extension(name).toLowerCase()) {
  '.png' => 'image/png',
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.gif' => 'image/gif',
  '.webp' => 'image/webp',
  _ => null,
};

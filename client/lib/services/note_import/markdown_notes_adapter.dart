// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'note_import_model.dart';

final RegExp _notionIdSuffix = RegExp(r'\s+[0-9a-fA-F]{32}(?:_all)?$');
final RegExp _checkbox = RegExp(r'^\s*[-*+]\s+\[([ xX])\]\s*(.*)$');
final RegExp _unordered = RegExp(r'^\s*[-*+]\s+(.*)$');
final RegExp _ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$');
final RegExp _standardImage = RegExp(r'^\s*!\[[^\]]*\]\(([^)]+)\)\s*$');
final RegExp _wikiImage = RegExp(r'^\s*!\[\[([^\]|]+)(?:\|[^\]]+)?\]\]\s*$');

String _decodeText(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

String _withoutExtension(String name) {
  final int dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String _stripNotionSuffix(String value) =>
    value.replaceFirst(_notionIdSuffix, '').trim();

String _normaliseRelative(String value, {required bool decodePercent}) {
  final List<String> out = <String>[];
  for (final String part in value.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    if (!decodePercent) {
      out.add(part);
      continue;
    }
    try {
      out.add(Uri.decodeComponent(part));
    } on ArgumentError {
      // A malformed percent escape belongs to this link, not the whole note.
      out.add(part);
    }
  }
  return out.join('/');
}

String? _mimeFor(String name) => switch (p.extension(name).toLowerCase()) {
  '.png' => 'image/png',
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.gif' => 'image/gif',
  '.webp' => 'image/webp',
  '.bmp' => 'image/bmp',
  _ => null,
};

class MarkdownNotesAdapter implements NoteImportAdapter {
  const MarkdownNotesAdapter({required this.notion});

  final bool notion;

  @override
  Stream<NoteImportAdapterEvent> read(NoteImportSource source) async* {
    final List<NoteImportEntry> entries = await source.entries().toList();
    final Map<String, NoteImportEntry> byPath = <String, NoteImportEntry>{
      for (final NoteImportEntry entry in entries) entry.path: entry,
    };
    bool found = false;
    for (final NoteImportEntry entry in entries) {
      final String lower = entry.path.toLowerCase();
      final List<String> components = entry.path.split('/');
      if (!notion &&
          (components.contains('.obsidian') || components.contains('.trash'))) {
        continue;
      }
      if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
        found = true;
        try {
          yield NoteImportNoteEvent(await _readMarkdown(entry, byPath));
        } catch (error) {
          yield NoteImportSkipEvent(
            NoteImportSkip(
              sourceName: entry.path,
              reason: 'Unreadable Markdown: $error',
            ),
          );
        }
      } else if (notion && lower.endsWith('.csv')) {
        if (_isNotionAllTwin(entry.path, byPath)) continue;
        found = true;
        try {
          final ImportedNote? note = await _readCsv(entry);
          if (note == null) {
            yield NoteImportSkipEvent(
              NoteImportSkip(sourceName: entry.path, reason: 'CSV has no rows'),
            );
          } else {
            yield NoteImportNoteEvent(note);
          }
        } catch (error) {
          yield NoteImportSkipEvent(
            NoteImportSkip(
              sourceName: entry.path,
              reason: 'Unsupported CSV: $error',
            ),
          );
        }
      }
    }
    if (!found) {
      yield NoteImportSkipEvent(
        NoteImportSkip(
          sourceName: source.displayName,
          reason: notion
              ? 'No Markdown or CSV files found'
              : 'No Markdown files found',
        ),
      );
    }
  }

  Future<ImportedNote> _readMarkdown(
    NoteImportEntry entry,
    Map<String, NoteImportEntry> byPath,
  ) async {
    final String text = _decodeText(await entry.readBytes());
    final String directory = p.posix.dirname(entry.path) == '.'
        ? ''
        : p.posix.dirname(entry.path);
    final List<ImportedNoteBlock> blocks = <ImportedNoteBlock>[];
    final StringBuffer paragraph = StringBuffer();

    void flushParagraph() {
      final String value = paragraph.toString().trim();
      if (value.isNotEmpty) blocks.add(ImportedText(value));
      paragraph.clear();
    }

    Future<void> image(String target, {required bool wiki}) async {
      flushParagraph();
      final String cleanTarget = target
          .split('#')
          .first
          .split('?')
          .first
          .trim();
      final String rootRelative = _normaliseRelative(
        cleanTarget,
        decodePercent: notion,
      );
      final String noteRelative = _normaliseRelative(
        directory.isEmpty ? cleanTarget : '$directory/$cleanTarget',
        decodePercent: notion,
      );
      final List<String> candidates = wiki
          ? <String>[rootRelative, noteRelative]
          : <String>[noteRelative];
      NoteImportEntry? asset;
      for (final String candidate in candidates) {
        asset ??= byPath[candidate];
      }
      if (asset == null && target == cleanTarget) {
        final List<NoteImportEntry> named = byPath.values
            .where(
              (candidate) => candidate.name == p.posix.basename(noteRelative),
            )
            .toList(growable: false);
        if (named.length == 1) asset = named.single;
      }
      final String? mime = _mimeFor(asset?.path ?? noteRelative);
      if (asset == null || mime == null) {
        blocks.add(ImportedAttachmentProblem('Attachment skipped: $target'));
        return;
      }
      blocks.add(
        ImportedImage(
          name: asset.name,
          bytes: await asset.readBytes(),
          mime: mime,
        ),
      );
    }

    String? fence;
    for (final String rawLine in const LineSplitter().convert(text)) {
      final String line = rawLine.trimRight();
      final RegExpMatch? fenceMatch = RegExp(r'^\s*(```|~~~)').firstMatch(line);
      if (fence != null) {
        if (paragraph.isNotEmpty) paragraph.writeln();
        paragraph.write(line);
        if (fenceMatch?.group(1) == fence) {
          fence = null;
          flushParagraph();
        }
        continue;
      }
      if (fenceMatch != null) {
        flushParagraph();
        fence = fenceMatch.group(1);
        paragraph.write(line);
        continue;
      }
      final RegExpMatch? standard = _standardImage.firstMatch(line);
      final RegExpMatch? wiki = _wikiImage.firstMatch(line);
      if (standard != null || wiki != null) {
        await image((standard ?? wiki)!.group(1)!, wiki: wiki != null);
        continue;
      }
      final RegExpMatch? check = _checkbox.firstMatch(line);
      if (check != null) {
        flushParagraph();
        blocks.add(
          ImportedChecklistItem(
            check.group(2)!.trim(),
            checked: check.group(1)!.toLowerCase() == 'x',
          ),
        );
        continue;
      }
      final RegExpMatch? bullet = _unordered.firstMatch(line);
      final RegExpMatch? ordered = _ordered.firstMatch(line);
      if (bullet != null || ordered != null) {
        flushParagraph();
        blocks.add(ImportedText((bullet ?? ordered)!.group(1)!.trim()));
        continue;
      }
      if (line.trim().isEmpty) {
        flushParagraph();
        continue;
      }
      final String heading = line.replaceFirst(
        RegExp(r'^\s{0,3}#{1,6}\s+'),
        '',
      );
      if (heading != line) {
        flushParagraph();
        blocks.add(ImportedText(heading));
      } else {
        if (paragraph.isNotEmpty) paragraph.writeln();
        paragraph.write(line.trim());
      }
    }
    flushParagraph();
    if (blocks.isEmpty) blocks.add(const ImportedText('(empty note)'));

    String title = _withoutExtension(entry.name);
    if (notion) title = _stripNotionSuffix(title);
    title = title.trim().isEmpty ? 'Untitled note' : title.trim();
    return ImportedNote(
      sourceName: entry.path,
      title: title,
      folderHint: _folderHint(directory),
      createdAt: entry.modifiedAt,
      updatedAt: entry.modifiedAt,
      blocks: blocks,
    );
  }

  String? _folderHint(String directory) {
    if (directory.isEmpty) return notion ? 'Notion' : 'Obsidian';
    final Iterable<String> components = directory
        .split('/')
        .map((part) => notion ? _stripNotionSuffix(part) : part);
    return '${notion ? 'Notion' : 'Obsidian'} / ${components.join(' / ')}';
  }

  Future<ImportedNote?> _readCsv(NoteImportEntry entry) async {
    final String source = _decodeText(await entry.readBytes());
    final List<List<String>> rows = _parseCsv(source);
    if (rows.isEmpty) return null;
    final int columns = rows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    if (columns == 0) return null;
    final StringBuffer table = StringBuffer();
    for (int rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final List<String> row = rows[rowIndex];
      table.writeln(
        '| ${List<String>.generate(columns, (i) => i < row.length ? row[i].replaceAll('|', r'\|') : '').join(' | ')} |',
      );
      if (rowIndex == 0) {
        table.writeln('| ${List<String>.filled(columns, '---').join(' | ')} |');
      }
    }
    final String directory = p.posix.dirname(entry.path) == '.'
        ? ''
        : p.posix.dirname(entry.path);
    return ImportedNote(
      sourceName: entry.path,
      title: _stripNotionSuffix(_withoutExtension(entry.name)),
      folderHint: _folderHint(directory),
      createdAt: entry.modifiedAt,
      updatedAt: entry.modifiedAt,
      blocks: <ImportedNoteBlock>[ImportedText(table.toString().trimRight())],
    );
  }
}

bool _isNotionAllTwin(String path, Map<String, NoteImportEntry> byPath) {
  final String extension = p.posix.extension(path);
  final String stem = path.substring(0, path.length - extension.length);
  if (!stem.toLowerCase().endsWith('_all')) return false;
  final String plain = '${stem.substring(0, stem.length - 4)}$extension';
  return byPath.containsKey(plain);
}

List<List<String>> _parseCsv(String source) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer field = StringBuffer();
  bool quoted = false;
  for (int i = 0; i < source.length; i++) {
    final String char = source[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < source.length && source[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(char);
      }
    } else if (char == '"' && field.isEmpty) {
      quoted = true;
    } else if (char == ',') {
      row.add(field.toString());
      field.clear();
    } else if (char == '\n' || char == '\r') {
      if (char == '\r' && i + 1 < source.length && source[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      if (row.any((value) => value.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      field.write(char);
    }
  }
  if (quoted) throw const FormatException('unclosed quoted field');
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    if (row.any((value) => value.isNotEmpty)) rows.add(row);
  }
  return rows;
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'note_import_model.dart';

class EvernoteEnexAdapter implements NoteImportAdapter {
  const EvernoteEnexAdapter();

  @override
  Stream<NoteImportAdapterEvent> read(NoteImportSource source) async* {
    final List<NoteImportEntry> entries = await source.entries().toList();
    final List<NoteImportEntry> enex = entries
        .where((entry) => entry.path.toLowerCase().endsWith('.enex'))
        .toList(growable: false);
    if (enex.isEmpty) {
      yield NoteImportSkipEvent(
        NoteImportSkip(
          sourceName: source.displayName,
          reason: 'No Evernote ENEX file found',
        ),
      );
      return;
    }
    for (final NoteImportEntry entry in enex) {
      XmlDocument document;
      try {
        document = XmlDocument.parse(
          utf8.decode(await entry.readBytes(), allowMalformed: true),
        );
      } catch (error) {
        yield NoteImportSkipEvent(
          NoteImportSkip(
            sourceName: entry.path,
            reason: 'Unreadable ENEX XML: $error',
          ),
        );
        continue;
      }
      final List<XmlElement> notes = document.findAllElements('note').toList();
      if (notes.isEmpty) {
        yield NoteImportSkipEvent(
          NoteImportSkip(
            sourceName: entry.path,
            reason: 'ENEX contains no notes',
          ),
        );
      }
      for (int i = 0; i < notes.length; i++) {
        final XmlElement note = notes[i];
        try {
          yield NoteImportNoteEvent(_decodeNote(note, entry.path, i + 1));
        } catch (error) {
          final String title =
              note.getElement('title')?.innerText.trim() ?? 'note ${i + 1}';
          yield NoteImportSkipEvent(
            NoteImportSkip(
              sourceName: '${entry.path} — $title',
              reason: 'Unreadable Evernote note: $error',
            ),
          );
        }
      }
    }
  }

  ImportedNote _decodeNote(XmlElement note, String sourceName, int index) {
    final String title = note.getElement('title')?.innerText.trim() ?? '';
    final XmlElement? contentElement = note.getElement('content');
    if (contentElement == null) throw const FormatException('missing content');
    final XmlDocument enml = XmlDocument.parse(
      _expandCommonHtmlEntities(contentElement.innerText),
    );

    final Map<String, _EvernoteResource> resources =
        <String, _EvernoteResource>{};
    for (final XmlElement resource in note.findElements('resource')) {
      final XmlElement? data = resource.getElement('data');
      final String? mime = resource.getElement('mime')?.innerText.trim();
      if (data == null || mime == null) continue;
      try {
        final Uint8List bytes = base64Decode(
          data.innerText.replaceAll(RegExp(r'\s'), ''),
        );
        final String hash =
            data.getAttribute('hash')?.toLowerCase() ??
            md5.convert(bytes).toString();
        final String fileName =
            resource
                .getElement('resource-attributes')
                ?.getElement('file-name')
                ?.innerText
                .trim() ??
            'Evernote attachment';
        resources[hash] = _EvernoteResource(
          bytes: bytes,
          mime: mime,
          name: fileName,
        );
      } catch (_) {
        // A corresponding en-media element gets a visible skipped line below.
      }
    }

    final List<ImportedNoteBlock> blocks = <ImportedNoteBlock>[];
    if (enml.findAllElements('table').isNotEmpty) {
      blocks.add(
        const ImportedAttachmentProblem(
          'Evernote table flattened to tab-separated text',
        ),
      );
    }
    final StringBuffer text = StringBuffer();
    bool? checked;

    void flush() {
      final String value = text
          .toString()
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .trim();
      text.clear();
      if (value.isEmpty) {
        checked = null;
        return;
      }
      final bool? todo = checked;
      checked = null;
      if (todo == null) {
        blocks.add(ImportedText(value));
      } else {
        blocks.add(ImportedChecklistItem(value, checked: todo));
      }
    }

    void visit(XmlNode node) {
      if (node is XmlText || node is XmlCDATA) {
        text.write(node.value ?? '');
        return;
      }
      if (node is! XmlElement) return;
      final String name = node.name.local.toLowerCase();
      if (name == 'li' &&
          node.parentElement?.name.local.toLowerCase() == 'ul' &&
          _hasStyleFlag(node.parentElement, '--en-todo', expected: 'true')) {
        flush();
        checked = _hasStyleFlag(node, '--en-checked', expected: 'true');
      }
      if (name == 'en-todo') {
        flush();
        final String value =
            node.getAttribute('checked')?.toLowerCase() ?? 'false';
        checked = value == 'true' || value == 'checked';
        return;
      }
      if (name == 'en-media') {
        flush();
        final String hash = node.getAttribute('hash')?.toLowerCase() ?? '';
        final _EvernoteResource? resource = resources.remove(hash);
        if (resource == null || !resource.mime.startsWith('image/')) {
          blocks.add(
            ImportedAttachmentProblem(
              'Attachment skipped: ${node.getAttribute('type') ?? hash.nullIfEmpty ?? 'unknown attachment'}',
            ),
          );
        } else {
          blocks.add(
            ImportedImage(
              name: resource.name,
              bytes: resource.bytes,
              mime: resource.mime,
            ),
          );
        }
        return;
      }
      if (name == 'en-crypt') {
        flush();
        blocks.add(
          const ImportedAttachmentProblem('Encrypted Evernote content skipped'),
        );
        return;
      }
      if (name == 'br') {
        text.writeln();
        return;
      }
      for (final XmlNode child in node.children) {
        visit(child);
      }
      if (name == 'td' || name == 'th') {
        text.write('\t');
      } else if (name == 'tr') {
        text.writeln();
      }
      if (name == 'div' ||
          name == 'p' ||
          name == 'li' ||
          name == 'table' ||
          name == 'h1' ||
          name == 'h2' ||
          name == 'h3') {
        flush();
      }
    }

    visit(enml.rootElement);
    flush();
    for (final _EvernoteResource resource in resources.values) {
      if (resource.mime.startsWith('image/')) {
        blocks.add(
          ImportedImage(
            name: resource.name,
            bytes: resource.bytes,
            mime: resource.mime,
          ),
        );
      } else {
        blocks.add(
          ImportedAttachmentProblem('Attachment skipped: ${resource.name}'),
        );
      }
    }
    final List<String> tags =
        note
            .findElements('tag')
            .map((tag) => tag.innerText.trim())
            .where((tag) => tag.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (tags.isNotEmpty) {
      blocks.add(ImportedText('Evernote tags: ${tags.join(', ')}'));
    }
    if (blocks.isEmpty) blocks.add(const ImportedText('(empty note)'));

    final String? notebook =
        note.getAttribute('notebook')?.trim().nullIfEmpty ??
        note.getElement('notebook')?.innerText.trim().nullIfEmpty;
    final DateTime? created = _parseEvernoteDate(
      note.getElement('created')?.innerText,
    );
    final DateTime? updated = _parseEvernoteDate(
      note.getElement('updated')?.innerText,
    );
    return ImportedNote(
      sourceName: '$sourceName#$index',
      title: title.isEmpty ? 'Untitled Evernote note' : title,
      folderHint: notebook == null ? 'Evernote' : 'Evernote / $notebook',
      createdAt: created,
      updatedAt: updated ?? created,
      blocks: blocks,
    );
  }
}

class _EvernoteResource {
  const _EvernoteResource({
    required this.bytes,
    required this.mime,
    required this.name,
  });
  final Uint8List bytes;
  final String mime;
  final String name;
}

bool _hasStyleFlag(
  XmlElement? element,
  String property, {
  required String expected,
}) {
  final String style = element?.getAttribute('style') ?? '';
  for (final String declaration in style.split(';')) {
    final int colon = declaration.indexOf(':');
    if (colon < 0) continue;
    if (declaration.substring(0, colon).trim().toLowerCase() == property &&
        declaration.substring(colon + 1).trim().toLowerCase() == expected) {
      return true;
    }
  }
  return false;
}

String _expandCommonHtmlEntities(String input) {
  const Map<String, String> entities = <String, String>{
    'nbsp': '\u00a0',
    'iexcl': '¡',
    'cent': '¢',
    'pound': '£',
    'yen': '¥',
    'copy': '©',
    'reg': '®',
    'deg': '°',
    'plusmn': '±',
    'middot': '·',
    'times': '×',
    'divide': '÷',
    'ndash': '–',
    'mdash': '—',
    'lsquo': '‘',
    'rsquo': '’',
    'sbquo': '‚',
    'ldquo': '“',
    'rdquo': '”',
    'bdquo': '„',
    'dagger': '†',
    'Dagger': '‡',
    'bull': '•',
    'hellip': '…',
    'permil': '‰',
    'prime': '′',
    'Prime': '″',
    'lsaquo': '‹',
    'rsaquo': '›',
    'euro': '€',
    'trade': '™',
    'larr': '←',
    'uarr': '↑',
    'rarr': '→',
    'darr': '↓',
    'harr': '↔',
  };
  return input.replaceAllMapped(RegExp(r'&([A-Za-z][A-Za-z0-9]+);'), (match) {
    final String name = match.group(1)!;
    return entities[name] ?? match.group(0)!;
  });
}

DateTime? _parseEvernoteDate(String? value) {
  if (value == null) return null;
  final RegExpMatch? match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$',
  ).firstMatch(value.trim());
  if (match == null) return DateTime.tryParse(value)?.toUtc();
  return DateTime.utc(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

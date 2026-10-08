// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/services/note_import/evernote_enex_adapter.dart';
import 'package:tangent/services/note_import/google_keep_adapter.dart';
import 'package:tangent/services/note_import/markdown_notes_adapter.dart';
import 'package:tangent/services/note_import/note_import_model.dart';
import 'package:tangent/services/note_import/note_import_source.dart';

String fixture(String relative) =>
    p.join('test', 'fixtures', 'import', relative);

Future<List<NoteImportAdapterEvent>> readAll(
  NoteImportAdapter adapter,
  NoteImportSource source,
) => adapter.read(source).toList();

void main() {
  test(
    'Google Keep maps text, checklist, labels, timestamp and image',
    () async {
      final DirectoryNoteImportSource source =
          await DirectoryNoteImportSource.open(fixture('keep'));

      final List<NoteImportAdapterEvent> events = await readAll(
        const GoogleKeepAdapter(),
        source,
      );

      final ImportedNote note = (events.single as NoteImportNoteEvent).note;
      expect(note.title, 'Groceries');
      expect(note.folderHint, 'Google Keep / Home');
      expect(note.updatedAt, DateTime.utc(2026, 6, 1, 10));
      expect(
        note.blocks.whereType<ImportedText>().single.text,
        'Remember reusable bags',
      );
      expect(
        note.blocks.whereType<ImportedChecklistItem>().map(
          (item) => (item.text, item.checked),
        ),
        <(String, bool)>[('Milk', false), ('Coffee', true)],
      );
      expect(note.blocks.whereType<ImportedImage>(), hasLength(1));
    },
  );

  test('Google Keep reads the same Takeout from a ZIP', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'keep-import-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final Archive archive = Archive();
    for (final String name in <String>['Groceries.json', 'tiny.png']) {
      final List<int> bytes = await File(
        p.join(fixture('keep'), name),
      ).readAsBytes();
      archive.addFile(ArchiveFile.bytes('Takeout/Keep/$name', bytes));
    }
    final File zip = File(p.join(temp.path, 'keep.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));

    final List<NoteImportAdapterEvent> events = await readAll(
      const GoogleKeepAdapter(),
      await ZipNoteImportSource.open(zip.path),
    );

    expect(events.whereType<NoteImportNoteEvent>(), hasLength(1));
    expect(
      (events.whereType<NoteImportNoteEvent>().single).note.blocks
          .whereType<ImportedImage>(),
      hasLength(1),
    );
  });

  test(
    'Evernote ENEX maps two notes, todo, image, dates and notebook attr',
    () async {
      final FileNoteImportSource source = await FileNoteImportSource.open(
        fixture(p.join('evernote', 'two-notes.enex')),
      );

      final List<NoteImportAdapterEvent> events = await readAll(
        const EvernoteEnexAdapter(),
        source,
      );

      final List<ImportedNote> notes = events
          .whereType<NoteImportNoteEvent>()
          .map((event) => event.note)
          .toList();
      expect(notes.map((note) => note.title), <String>[
        'Planning',
        'Second note',
      ]);
      expect(notes.first.folderHint, 'Evernote / Work');
      expect(notes.first.createdAt, DateTime.utc(2026, 10, 1, 10, 15));
      expect(notes.first.updatedAt, DateTime.utc(2026, 10, 2, 11, 15));
      expect(
        notes.first.blocks.whereType<ImportedChecklistItem>().single.checked,
        isTrue,
      );
      expect(notes.first.blocks.whereType<ImportedImage>(), hasLength(1));
      expect(
        (notes.last.blocks.single as ImportedText).text,
        'Line one\nLine two',
      );
    },
  );

  test(
    'Notion strips 32-hex suffixes and imports Markdown plus CSV table',
    () async {
      final DirectoryNoteImportSource source =
          await DirectoryNoteImportSource.open(fixture('notion'));

      final List<NoteImportAdapterEvent> events = await readAll(
        const MarkdownNotesAdapter(notion: true),
        source,
      );

      final List<ImportedNote> notes = events
          .whereType<NoteImportNoteEvent>()
          .map((event) => event.note)
          .toList();
      expect(notes.map((note) => note.title).toSet(), <String>{
        'Project Alpha',
        'People',
      });
      expect(notes.every((note) => note.folderHint == 'Notion / Team'), isTrue);
      final ImportedNote project = notes.singleWhere(
        (note) => note.title == 'Project Alpha',
      );
      expect(
        project.blocks.whereType<ImportedChecklistItem>().single.checked,
        isTrue,
      );
      expect(project.blocks.whereType<ImportedImage>(), hasLength(1));
      final ImportedNote people = notes.singleWhere(
        (note) => note.title == 'People',
      );
      expect(
        (people.blocks.single as ImportedText).text,
        contains('| Ada | Done | first, quoted |'),
      );
    },
  );

  test(
    'Obsidian maps nested folder, checkbox and wiki-relative image',
    () async {
      final DirectoryNoteImportSource source =
          await DirectoryNoteImportSource.open(fixture('obsidian'));

      final List<NoteImportAdapterEvent> events = await readAll(
        const MarkdownNotesAdapter(notion: false),
        source,
      );

      final ImportedNote note = (events.single as NoteImportNoteEvent).note;
      expect(note.title, '2026-10-07');
      expect(note.folderHint, 'Obsidian / Journal');
      expect(note.blocks.whereType<ImportedChecklistItem>(), hasLength(2));
      expect(note.blocks.whereType<ImportedImage>(), hasLength(1));
    },
  );

  test('ZIP source rejects parent traversal before reading content', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'unsafe-import-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final Archive archive = Archive()
      ..addFile(ArchiveFile.string('../outside.md', 'not safe'));
    final File zip = File(p.join(temp.path, 'unsafe.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));

    expect(() => ZipNoteImportSource.open(zip.path), throwsFormatException);
  });
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:io' as io show ProcessInfo, ZLibEncoder;
import 'dart:convert';
import 'dart:typed_data';

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

class _MemorySource implements NoteImportSource {
  _MemorySource(Map<String, List<int>> files)
    : files = <NoteImportEntry>[
        for (final MapEntry<String, List<int>> file in files.entries)
          NoteImportEntry(
            path: file.key,
            size: file.value.length,
            readBytes: () async => Uint8List.fromList(file.value),
            modifiedAt: DateTime.utc(2026, 10, 1),
          ),
      ];

  final List<NoteImportEntry> files;

  @override
  String get displayName => 'memory';

  @override
  Stream<NoteImportEntry> entries() => Stream.fromIterable(files);

  @override
  Future<NoteImportEntry?> find(String relativePath) async {
    for (final NoteImportEntry entry in files) {
      if (entry.path == relativePath) return entry;
    }
    return null;
  }
}

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
    'ZIP scan closes the file and does not cache decompressed entries',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'stream-zip-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File zip = File(p.join(temp.path, 'notes.zip'))
        ..writeAsBytesSync(
          ZipEncoder().encode(
            Archive()..addFile(ArchiveFile.string('note.md', 'hello')),
          ),
        );
      final ZipNoteImportSource source = await ZipNoteImportSource.open(
        zip.path,
      );
      final NoteImportEntry entry = await source.entries().single;

      zip.renameSync(p.join(temp.path, 'moved.zip'));
      await expectLater(entry.readBytes(), throwsA(isA<FileSystemException>()));
    },
  );

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

  test('Keep skips trash, sorts labels, preserves created time, uses jpeg '
      'sibling, and blocks attachment traversal', () async {
    final List<int> png = await File(
      p.join(fixture('keep'), 'tiny.png'),
    ).readAsBytes();
    final _MemorySource source = _MemorySource(<String, List<int>>{
      'Takeout/Keep/note.json': utf8.encode(
        jsonEncode(<String, Object>{
          'title': 'Keep seams',
          'textContent': 'body',
          'createdTimestampUsec': '1000000',
          'userEditedTimestampUsec': '2000000',
          'labels': <Object>[
            <String, String>{'name': 'Zulu'},
            <String, String>{'name': 'Alpha'},
          ],
          'attachments': <Object>[
            <String, String>{'filePath': 'photo.jpg'},
            <String, String>{'filePath': '../../secret.png'},
          ],
        }),
      ),
      'Takeout/Keep/photo.jpeg': png,
      'secret.png': png,
      'Takeout/Keep/trash.json': utf8.encode(
        jsonEncode(<String, Object>{
          'title': 'Deleted',
          'textContent': 'do not restore',
          'isTrashed': true,
        }),
      ),
    });

    final List<NoteImportAdapterEvent> events = await readAll(
      const GoogleKeepAdapter(),
      source,
    );
    final ImportedNote note = events
        .whereType<NoteImportNoteEvent>()
        .single
        .note;
    expect(note.folderHint, 'Google Keep / Alpha');
    expect(
      note.createdAt,
      DateTime.fromMicrosecondsSinceEpoch(1000000, isUtc: true),
    );
    expect(
      note.updatedAt,
      DateTime.fromMicrosecondsSinceEpoch(2000000, isUtc: true),
    );
    expect(note.blocks.whereType<ImportedImage>(), hasLength(1));
    expect(
      note.blocks.whereType<ImportedText>().map((block) => block.text),
      contains('Google Keep labels: Alpha, Zulu'),
    );
    expect(
      note.blocks.whereType<ImportedAttachmentProblem>().single.message,
      contains('../../secret.png'),
    );
    expect(
      events.whereType<NoteImportSkipEvent>().single.skip.reason,
      contains('trash'),
    );
  });

  test('Evernote 10 todos, entities, table flattening, tags, and skip source '
      'remain visible', () async {
    final String enex = '''<?xml version="1.0" encoding="UTF-8"?>
<en-export>
  <note notebook="Work"><title>Modern</title><tag>beta</tag><tag>alpha</tag>
    <content><![CDATA[<en-note><div>a&nbsp;b &mdash; it&rsquo;s</div>
      <ul style="--en-todo:true;"><li style="--en-checked:true;">Done</li>
      <li style="--en-checked:false;">Open</li></ul>
      <table><tr><td>a1</td><td>b1</td></tr><tr><td>a2</td><td>b2</td></tr></table>
    </en-note>]]></content>
  </note>
  <note><title>Missing</title></note>
</en-export>''';
    final List<NoteImportAdapterEvent> events = await readAll(
      const EvernoteEnexAdapter(),
      _MemorySource(<String, List<int>>{'modern.enex': utf8.encode(enex)}),
    );

    final ImportedNote note = events
        .whereType<NoteImportNoteEvent>()
        .single
        .note;
    expect(
      note.blocks.whereType<ImportedChecklistItem>().map(
        (item) => (item.text, item.checked),
      ),
      <(String, bool)>[('Done', true), ('Open', false)],
    );
    final List<String> text = note.blocks
        .whereType<ImportedText>()
        .map((block) => block.text)
        .toList();
    expect(text, contains('a\u00a0b — it’s'));
    expect(text, contains('a1\tb1\na2\tb2'));
    expect(text, contains('Evernote tags: alpha, beta'));
    expect(
      note.blocks.whereType<ImportedAttachmentProblem>().single.message,
      contains('table flattened'),
    );
    expect(
      events.whereType<NoteImportSkipEvent>().single.skip.sourceName,
      'modern.enex — Missing',
    );
  });

  test(
    'Markdown preserves percent paths, uppercase and empty checks, code '
    'fences, vault-root wiki links, basename fallback, and skips trash',
    () async {
      final List<int> png = await File(
        p.join(fixture('keep'), 'tiny.png'),
      ).readAsBytes();
      final _MemorySource source = _MemorySource(<String, List<int>>{
        '50% done/Journal/note.md': utf8.encode('''- [X] upper
- [x]
![[images/root.png]]
![[fallback.png]]
![[Report 50%.png]]
```dart
- not a bullet
- [x] not a checkbox
```'''),
        'images/root.png': png,
        '50% done/Journal/images/root.png': <int>[...png, 0],
        'other/fallback.png': png,
        '50% done/Journal/Report 50%.png': png,
        '.trash/deleted.md': utf8.encode('deleted'),
      });

      final List<NoteImportAdapterEvent> events = await readAll(
        const MarkdownNotesAdapter(notion: false),
        source,
      );
      final ImportedNote note = events
          .whereType<NoteImportNoteEvent>()
          .single
          .note;
      expect(note.folderHint, 'Obsidian / 50% done / Journal');
      expect(
        note.blocks.whereType<ImportedChecklistItem>().map(
          (item) => (item.text, item.checked),
        ),
        <(String, bool)>[('upper', true), ('', true)],
      );
      expect(note.blocks.whereType<ImportedImage>(), hasLength(3));
      expect(
        note.blocks.whereType<ImportedImage>().first.bytes.length,
        png.length,
        reason: 'vault-root image wins over the note-relative duplicate',
      );
      expect(
        note.blocks.whereType<ImportedText>().single.text,
        '```dart\n- not a bullet\n- [x] not a checkbox\n```',
      );
      expect(events.whereType<NoteImportSkipEvent>(), isEmpty);
    },
  );

  test(
    'Notion decodes percent paths and skips _all CSV when plain twin exists',
    () async {
      const String id = '0123456789abcdef0123456789abcdef';
      final List<int> png = await File(
        p.join(fixture('keep'), 'tiny.png'),
      ).readAsBytes();
      final List<NoteImportAdapterEvent> events = await readAll(
        const MarkdownNotesAdapter(notion: true),
        _MemorySource(<String, List<int>>{
          'Team $id/Page $id.md': utf8.encode('![](My%20Image.png)'),
          'Team $id/My Image.png': png,
          'Team $id/People $id.csv': utf8.encode('Name\nAda'),
          'Team $id/People ${id}_all.csv': utf8.encode('Name\nDuplicate'),
        }),
      );

      final List<ImportedNote> notes = events
          .whereType<NoteImportNoteEvent>()
          .map((event) => event.note)
          .toList();
      expect(
        notes.map((note) => note.title),
        unorderedEquals(<String>['Page', 'People']),
      );
      expect(
        notes
            .singleWhere((note) => note.title == 'Page')
            .blocks
            .whereType<ImportedImage>(),
        hasLength(1),
      );
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

  test('ZIP source rejects absolute paths', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'absolute-import-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final Archive archive = Archive()
      ..addFile(ArchiveFile.string('C:/outside.md', 'not safe'));
    final File zip = File(p.join(temp.path, 'absolute.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));

    expect(() => ZipNoteImportSource.open(zip.path), throwsFormatException);
  });

  test(
    'ZIP inflation aborts on actual output beyond a forged small header',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'bomb-import-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File zip = File(p.join(temp.path, 'bomb.zip'));
      _writeDeflateBomb(
        zip,
        name: 'bomb.md',
        actualSize: 128 * 1024 * 1024,
        advertisedSize: 1000,
      );

      final int rssBefore = io.ProcessInfo.currentRss;
      final Stopwatch stopwatch = Stopwatch()..start();
      await expectLater(
        ZipNoteImportSource.open(zip.path),
        throwsFormatException,
      );
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'the forged 128 MiB output must stop after about 1 KiB',
      );
      expect(
        io.ProcessInfo.currentRss - rssBefore,
        lessThan(32 * 1024 * 1024),
        reason: '128 MiB forged output must not be materialized',
      );
    },
  );

  test('ZIP actual entry output cannot cross the 64 MiB cap', () async {
    final Directory temp = await Directory.systemTemp.createTemp('entry-cap-');
    addTearDown(() => temp.delete(recursive: true));
    final File zip = File(p.join(temp.path, 'over-limit.zip'));
    _writeStoredZip(zip, 'large.bin', maxImportEntryBytes + 1);

    await expectLater(
      ZipNoteImportSource.open(zip.path),
      throwsFormatException,
    );
  });
}

void _writeDeflateBomb(
  File file, {
  required String name,
  required int actualSize,
  required int advertisedSize,
}) {
  final BytesBuilder compressedBuilder = BytesBuilder(copy: false);
  final ByteConversionSink sink = io.ZLibEncoder(raw: true)
      .startChunkedConversion(
        ByteConversionSink.withCallback(compressedBuilder.add),
      );
  final Uint8List chunk = Uint8List(64 * 1024);
  int remaining = actualSize;
  while (remaining > 0) {
    final int count = remaining < chunk.length ? remaining : chunk.length;
    sink.add(
      count == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, count),
    );
    remaining -= count;
  }
  sink.close();
  final Uint8List compressed = compressedBuilder.takeBytes();
  final Uint8List nameBytes = Uint8List.fromList(utf8.encode(name));
  final ByteData local = ByteData(30)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(8, 8, Endian.little)
    ..setUint32(18, compressed.length, Endian.little)
    ..setUint32(22, advertisedSize, Endian.little)
    ..setUint16(26, nameBytes.length, Endian.little);
  final int centralOffset = 30 + nameBytes.length + compressed.length;
  final ByteData central = ByteData(46)
    ..setUint32(0, 0x02014b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 20, Endian.little)
    ..setUint16(10, 8, Endian.little)
    ..setUint32(20, compressed.length, Endian.little)
    ..setUint32(24, advertisedSize, Endian.little)
    ..setUint16(28, nameBytes.length, Endian.little);
  final int centralSize = 46 + nameBytes.length;
  final ByteData end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, 1, Endian.little)
    ..setUint16(10, 1, Endian.little)
    ..setUint32(12, centralSize, Endian.little)
    ..setUint32(16, centralOffset, Endian.little);
  file.writeAsBytesSync(<int>[
    ...local.buffer.asUint8List(),
    ...nameBytes,
    ...compressed,
    ...central.buffer.asUint8List(),
    ...nameBytes,
    ...end.buffer.asUint8List(),
  ]);
}

void _writeStoredZip(File file, String name, int size) {
  final Uint8List nameBytes = Uint8List.fromList(utf8.encode(name));
  final ByteData local = ByteData(30)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 0, Endian.little)
    ..setUint16(8, 0, Endian.little)
    ..setUint32(14, 0, Endian.little)
    ..setUint32(18, size, Endian.little)
    ..setUint32(22, size, Endian.little)
    ..setUint16(26, nameBytes.length, Endian.little)
    ..setUint16(28, 0, Endian.little);
  final RandomAccessFile output = file.openSync(mode: FileMode.write);
  try {
    output.writeFromSync(local.buffer.asUint8List());
    output.writeFromSync(nameBytes);
    final Uint8List chunk = Uint8List(64 * 1024);
    int remaining = size;
    while (remaining > 0) {
      final int count = remaining < chunk.length ? remaining : chunk.length;
      output.writeFromSync(chunk, 0, count);
      remaining -= count;
    }

    final int centralOffset = 30 + nameBytes.length + size;
    final ByteData central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint32(16, 0, Endian.little)
      ..setUint32(20, size, Endian.little)
      ..setUint32(24, size, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, 0, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint16(34, 0, Endian.little)
      ..setUint16(36, 0, Endian.little)
      ..setUint32(38, 0, Endian.little)
      ..setUint32(42, 0, Endian.little);
    output.writeFromSync(central.buffer.asUint8List());
    output.writeFromSync(nameBytes);

    final int centralSize = 46 + nameBytes.length;
    final ByteData end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, 1, Endian.little)
      ..setUint16(10, 1, Endian.little)
      ..setUint32(12, centralSize, Endian.little)
      ..setUint32(16, centralOffset, Endian.little)
      ..setUint16(20, 0, Endian.little);
    output.writeFromSync(end.buffer.asUint8List());
  } finally {
    output.closeSync();
  }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as p;
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/note_import/google_keep_adapter.dart';
import 'package:tangent/services/note_import/note_import_model.dart';
import 'package:tangent/services/note_import/note_import_service.dart';
import 'package:tangent/services/note_import/note_import_source.dart';

class _MemoryStore implements NoteImportStore {
  _MemoryStore({Set<String>? titles, Map<String, String>? folders})
    : titles = titles ?? <String>{},
      folders = folders ?? <String, String>{};

  final Set<String> titles;
  final Map<String, String> folders;
  final List<Notebook> saved = <Notebook>[];
  int foldersCreated = 0;

  @override
  Future<String> createFolder(String name) async {
    final String id = 'folder-${++foldersCreated}';
    folders[name] = id;
    return id;
  }

  @override
  Future<Map<String, String>> loadFoldersByName() async =>
      Map<String, String>.of(folders);

  @override
  Future<Set<String>> loadNotebookTitles() async => Set<String>.of(titles);

  @override
  Future<void> saveNotebook(Notebook notebook) async {
    saved.add(notebook);
    titles.add(notebook.title);
  }
}

class _NotesAdapter implements NoteImportAdapter {
  const _NotesAdapter(this.notes);
  final List<ImportedNote> notes;

  @override
  Stream<NoteImportAdapterEvent> read(NoteImportSource source) async* {
    for (final ImportedNote note in notes) {
      yield NoteImportNoteEvent(note);
    }
  }
}

class _UnusedSource implements NoteImportSource {
  @override
  String get displayName => 'test source';

  @override
  Stream<NoteImportEntry> entries() => const Stream<NoteImportEntry>.empty();

  @override
  Future<NoteImportEntry?> find(String relativePath) async => null;
}

NoteImportService _service(_MemoryStore store) {
  int id = 0;
  return NoteImportService(
    store: store,
    idFactory: () => 'id-${++id}',
    now: () => DateTime.utc(2026, 10, 7, 12),
  );
}

void main() {
  test(
    'end-to-end Keep import creates folder, notebook title and block types',
    () async {
      final _MemoryStore store = _MemoryStore();
      final NoteImportReport report = await _service(store).import(
        adapter: const GoogleKeepAdapter(),
        source: await DirectoryNoteImportSource.open(
          p.join('test', 'fixtures', 'import', 'keep'),
        ),
      );

      expect(report.imported, 1);
      expect(report.skipped, 0);
      expect(store.folders, containsPair('Google Keep / Home', 'folder-1'));
      final Notebook notebook = store.saved.single;
      expect(notebook.title, 'Groceries');
      expect(notebook.folderId, 'folder-1');
      expect(notebook.createdAt, DateTime.utc(2026, 6, 1, 10));
      expect(notebook.updatedAt, DateTime.utc(2026, 6, 1, 10));
      expect(
        notebook.document.blocks.whereType<NotebookTextBlock>(),
        isNotEmpty,
      );
      expect(
        notebook.document.blocks.whereType<NotebookCheckboxBlock>(),
        hasLength(2),
      );
      expect(
        notebook.document.blocks.whereType<NotebookImageBlock>(),
        hasLength(1),
      );
    },
  );

  test('duplicate titles suffix (2), (3) across existing and batch', () async {
    final _MemoryStore store = _MemoryStore(
      titles: <String>{'Ideas', 'Ideas (2)'},
    );
    const ImportedNote first = ImportedNote(
      sourceName: 'one.md',
      title: 'Ideas',
      blocks: <ImportedNoteBlock>[ImportedText('one')],
      folderHint: 'Obsidian / Work',
    );
    const ImportedNote second = ImportedNote(
      sourceName: 'two.md',
      title: 'Ideas',
      blocks: <ImportedNoteBlock>[ImportedChecklistItem('two', checked: false)],
      folderHint: 'Obsidian / Work',
    );

    final NoteImportReport report = await _service(store).import(
      adapter: const _NotesAdapter(<ImportedNote>[first, second]),
      source: _UnusedSource(),
    );

    expect(report.imported, 2);
    expect(store.saved.map((notebook) => notebook.title), <String>[
      'Ideas (3)',
      'Ideas (4)',
    ]);
    expect(
      store.foldersCreated,
      1,
      reason: 'same source hierarchy reuses one Tangent folder',
    );
    expect(store.saved.first.document.blocks.single, isA<NotebookTextBlock>());
    expect(
      store.saved.last.document.blocks.single,
      isA<NotebookCheckboxBlock>(),
    );
  });

  test(
    'cancellation keeps imports already completed and stops before next note',
    () async {
      final _MemoryStore store = _MemoryStore();
      final NoteImportCancellationToken cancellation =
          NoteImportCancellationToken();
      const List<ImportedNote> notes = <ImportedNote>[
        ImportedNote(
          sourceName: 'one.md',
          title: 'One',
          blocks: <ImportedNoteBlock>[ImportedText('one')],
        ),
        ImportedNote(
          sourceName: 'two.md',
          title: 'Two',
          blocks: <ImportedNoteBlock>[ImportedText('two')],
        ),
      ];

      final NoteImportReport report = await _service(store).import(
        adapter: const _NotesAdapter(notes),
        source: _UnusedSource(),
        cancellationToken: cancellation,
        onEntry: (_) => cancellation.cancel(),
      );

      expect(report.cancelled, isTrue);
      expect(report.imported, 1);
      expect(store.saved.single.title, 'One');
    },
  );

  test('missing attachment becomes a visible notebook text line', () async {
    final _MemoryStore store = _MemoryStore();
    const ImportedNote note = ImportedNote(
      sourceName: 'broken.md',
      title: 'Broken image',
      blocks: <ImportedNoteBlock>[
        ImportedAttachmentProblem('Attachment skipped: missing.png'),
      ],
    );

    await _service(store).import(
      adapter: const _NotesAdapter(<ImportedNote>[note]),
      source: _UnusedSource(),
    );

    final NotebookTextBlock block =
        store.saved.single.document.blocks.single as NotebookTextBlock;
    expect(block.text, '[Attachment skipped: missing.png]');
  });

  test('source dates, empty checklist, and newline-aware positions survive '
      'service mapping', () async {
    final _MemoryStore store = _MemoryStore();
    final DateTime created = DateTime.utc(2020, 1, 2);
    final DateTime updated = DateTime.utc(2021, 3, 4);
    final String multiline = List<String>.generate(
      8,
      (index) => 'line $index',
    ).join('\n');
    final NoteImportReport report = await _service(store).import(
      adapter: _NotesAdapter(<ImportedNote>[
        ImportedNote(
          sourceName: 'position.md',
          title: 'Positioned',
          createdAt: created,
          updatedAt: updated,
          blocks: <ImportedNoteBlock>[
            ImportedText(multiline),
            const ImportedChecklistItem('', checked: true),
          ],
        ),
      ]),
      source: _UnusedSource(),
    );

    expect(report.imported, 1);
    final Notebook notebook = store.saved.single;
    expect(notebook.createdAt, created);
    expect(notebook.updatedAt, updated);
    final NotebookTextBlock text =
        notebook.document.blocks.first as NotebookTextBlock;
    final NotebookCheckboxBlock checkbox =
        notebook.document.blocks.last as NotebookCheckboxBlock;
    expect(text.x, isNotNull);
    expect(text.y, isNotNull);
    expect(checkbox.x, isNotNull);
    expect(checkbox.y, text.y! + 24 + 8 * 24);
    expect(checkbox.checked, isTrue);
    expect(checkbox.text, isEmpty);
  });

  test(
    'oversized imported images are resized to a 2048 edge before base64',
    () async {
      final _MemoryStore store = _MemoryStore();
      final image_lib.Image source = image_lib.Image(width: 2100, height: 1050);
      final Uint8List bytes = image_lib.encodePng(source);
      await _service(store).import(
        adapter: _NotesAdapter(<ImportedNote>[
          ImportedNote(
            sourceName: 'large.png',
            title: 'Large image',
            blocks: <ImportedNoteBlock>[
              ImportedImage(name: 'large.png', bytes: bytes, mime: 'image/png'),
            ],
          ),
        ]),
        source: _UnusedSource(),
      );

      final NotebookImageBlock block =
          store.saved.single.document.blocks.single as NotebookImageBlock;
      final image_lib.Image? decoded = image_lib.decodeImage(
        base64Decode(block.data),
      );
      expect(decoded, isNotNull);
      expect(decoded!.width, maxImportedImageEdge);
      expect(decoded.height, 1024);
      expect(block.mime, 'image/png');
    },
  );
}

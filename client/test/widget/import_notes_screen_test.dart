// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/settings/import_notes_screen.dart';
import 'package:tangent/services/note_import/note_import_service.dart';

class _Picker implements NoteImportPicker {
  _Picker(this.folder);
  final String? folder;

  @override
  bool get supportsDirectories => true;

  @override
  Future<String?> pickDirectory() async => folder;

  @override
  Future<String?> pickFile({
    required String label,
    required List<String> extensions,
  }) async => null;
}

class _Store implements NoteImportStore {
  final List<Notebook> saved = <Notebook>[];
  final Map<String, String> folders = <String, String>{};

  @override
  Future<String> createFolder(String name) async {
    final String id = 'folder-${folders.length + 1}';
    folders[name] = id;
    return id;
  }

  @override
  Future<Map<String, String>> loadFoldersByName() async => <String, String>{};

  @override
  Future<Set<String>> loadNotebookTitles() async => <String>{};

  @override
  Future<void> saveNotebook(Notebook notebook) async => saved.add(notebook);
}

Future<void> _settleImport(WidgetTester tester) async {
  for (int i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find
        .byKey(const ValueKey<String>('note-import-summary'))
        .evaluate()
        .isNotEmpty) {
      return;
    }
  }
  fail('note import did not finish');
}

void main() {
  testWidgets('source chooser explains all four import formats', (
    tester,
  ) async {
    final _Store store = _Store();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          noteImportPickerProvider.overrideWithValue(_Picker(null)),
          noteImportServiceProvider.overrideWithValue(
            NoteImportService(store: store),
          ),
        ],
        child: const MaterialApp(home: ImportNotesScreen()),
      ),
    );

    expect(find.text('Google Keep'), findsOneWidget);
    expect(find.text('Evernote'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
    expect(find.text('Obsidian / Markdown'), findsOneWidget);
    expect(find.textContaining('never change the source'), findsOneWidget);
  });

  testWidgets('completed import renders a scrollable itemized report', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _Store store = _Store();
    int id = 0;
    final NoteImportService service = NoteImportService(
      store: store,
      idFactory: () => 'id-${++id}',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          noteImportPickerProvider.overrideWithValue(
            _Picker(p.join('test', 'fixtures', 'import', 'keep')),
          ),
          noteImportServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: ImportNotesScreen()),
      ),
    );

    await tester.tap(find.text('Choose folder…').first);
    await _settleImport(tester);

    expect(store.saved, hasLength(1));
    expect(
      find.byKey(const ValueKey<String>('note-import-summary')),
      findsOneWidget,
    );
    expect(find.text('1 imported · 0 skipped'), findsOneWidget);
    await tester.fling(
      find.byKey(const ValueKey<String>('import-notes-report-scroll')),
      const Offset(0, -1200),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Imported as Groceries'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('import-notes-report-scroll')),
      findsOneWidget,
    );
  });

  testWidgets('cancelling the system picker leaves no report or notebooks', (
    tester,
  ) async {
    final _Store store = _Store();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          noteImportPickerProvider.overrideWithValue(_Picker(null)),
          noteImportServiceProvider.overrideWithValue(
            NoteImportService(store: store),
          ),
        ],
        child: const MaterialApp(home: ImportNotesScreen()),
      ),
    );

    await tester.tap(find.text('Choose folder…').first);
    await tester.pumpAndSettle();

    expect(store.saved, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('note-import-summary')),
      findsNothing,
    );
  });

  test('cancelled report text includes skipped count and kept wording', () {
    expect(noteImportSummaryTitle(1, 1), '1 imported · 1 skipped');
    expect(
      noteImportSummarySubtitle(true),
      'Cancelled — notebooks already imported were kept.',
    );
  });
}

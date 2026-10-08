// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/note_import/evernote_enex_adapter.dart';
import '../../services/note_import/google_keep_adapter.dart';
import '../../services/note_import/markdown_notes_adapter.dart';
import '../../services/note_import/note_import_model.dart';
import '../../services/note_import/note_import_service.dart';
import '../../services/note_import/note_import_source.dart';

abstract interface class NoteImportPicker {
  Future<String?> pickFile({
    required String label,
    required List<String> extensions,
  });
  Future<String?> pickDirectory();
  bool get supportsDirectories;
}

class SystemNoteImportPicker implements NoteImportPicker {
  @override
  bool get supportsDirectories =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Future<String?> pickFile({
    required String label,
    required List<String> extensions,
  }) async {
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(label: label, extensions: extensions),
      ],
    );
    return file?.path;
  }

  @override
  Future<String?> pickDirectory() => getDirectoryPath();
}

final noteImportPickerProvider = Provider<NoteImportPicker>(
  (_) => SystemNoteImportPicker(),
);

enum _ImportKind {
  keepZip,
  keepFolder,
  evernote,
  notionZip,
  notionFolder,
  obsidianFolder,
}

class ImportNotesScreen extends ConsumerStatefulWidget {
  const ImportNotesScreen({super.key});

  @override
  ConsumerState<ImportNotesScreen> createState() => _ImportNotesScreenState();
}

class _ImportNotesScreenState extends ConsumerState<ImportNotesScreen> {
  final List<NoteImportResultEntry> _entries = <NoteImportResultEntry>[];
  NoteImportCancellationToken? _cancellation;
  bool _running = false;
  bool _cancelled = false;

  Future<void> _start(_ImportKind kind) async {
    final NoteImportPicker picker = ref.read(noteImportPickerProvider);
    final String? path;
    switch (kind) {
      case _ImportKind.keepZip || _ImportKind.notionZip:
        path = await picker.pickFile(
          label: 'ZIP archives',
          extensions: const <String>['zip'],
        );
      case _ImportKind.evernote:
        path = await picker.pickFile(
          label: 'Evernote exports',
          extensions: const <String>['enex'],
        );
      case _ImportKind.keepFolder ||
          _ImportKind.notionFolder ||
          _ImportKind.obsidianFolder:
        path = await picker.pickDirectory();
    }
    if (path == null || path.isEmpty || !mounted) return;

    final NoteImportCancellationToken cancellation =
        NoteImportCancellationToken();
    setState(() {
      _running = true;
      _cancelled = false;
      _entries.clear();
      _cancellation = cancellation;
    });
    try {
      final NoteImportSource source = switch (kind) {
        _ImportKind.keepZip ||
        _ImportKind.notionZip => await ZipNoteImportSource.open(path),
        _ImportKind.evernote => await FileNoteImportSource.open(path),
        _ImportKind.keepFolder ||
        _ImportKind.notionFolder ||
        _ImportKind.obsidianFolder => await DirectoryNoteImportSource.open(
          path,
        ),
      };
      final NoteImportAdapter adapter = switch (kind) {
        _ImportKind.keepZip ||
        _ImportKind.keepFolder => const GoogleKeepAdapter(),
        _ImportKind.evernote => const EvernoteEnexAdapter(),
        _ImportKind.notionZip ||
        _ImportKind.notionFolder => const MarkdownNotesAdapter(notion: true),
        _ImportKind.obsidianFolder => const MarkdownNotesAdapter(notion: false),
      };
      final NoteImportReport report = await ref
          .read(noteImportServiceProvider)
          .import(
            adapter: adapter,
            source: source,
            cancellationToken: cancellation,
            onEntry: (NoteImportResultEntry entry) {
              if (mounted) setState(() => _entries.add(entry));
            },
          );
      if (mounted) setState(() => _cancelled = report.cancelled);
    } catch (error) {
      if (mounted) {
        setState(
          () => _entries.add(
            NoteImportResultEntry(
              kind: NoteImportResultKind.skipped,
              sourceName: path!,
              message: 'Import could not start: $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _cancellation = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final NoteImportPicker picker = ref.watch(noteImportPickerProvider);
    final int imported = _entries
        .where((e) => e.kind == NoteImportResultKind.imported)
        .length;
    final int skipped = _entries.length - imported;
    return Scaffold(
      appBar: AppBar(title: const Text('Import notes')),
      body: ListView(
        key: const ValueKey<String>('import-notes-report-scroll'),
        padding: const EdgeInsets.only(bottom: 40),
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Each source note becomes a Tangent notebook. Imports run only on this device and never change the source.',
            ),
          ),
          _SourceCard(
            title: 'Google Keep',
            subtitle: 'Google Takeout ZIP or extracted Keep folder',
            actions: <Widget>[
              _button('Choose Takeout ZIP…', _ImportKind.keepZip),
              if (picker.supportsDirectories)
                _button('Choose folder…', _ImportKind.keepFolder),
            ],
          ),
          _SourceCard(
            title: 'Evernote',
            subtitle: 'Evernote ENEX export',
            actions: <Widget>[_button('Choose ENEX…', _ImportKind.evernote)],
          ),
          _SourceCard(
            title: 'Notion',
            subtitle: 'Notion Markdown & CSV ZIP or extracted folder',
            actions: <Widget>[
              _button('Choose Notion ZIP…', _ImportKind.notionZip),
              if (picker.supportsDirectories)
                _button('Choose folder…', _ImportKind.notionFolder),
            ],
          ),
          _SourceCard(
            title: 'Obsidian / Markdown',
            subtitle:
                'Vault or plain Markdown folder, including relative images',
            actions: <Widget>[
              if (picker.supportsDirectories)
                _button('Choose Markdown folder…', _ImportKind.obsidianFolder),
              if (!picker.supportsDirectories)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Folder import is available on desktop.'),
                ),
            ],
          ),
          if (_running)
            ListTile(
              leading: const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Importing… $imported imported, $skipped skipped'),
              trailing: TextButton(
                key: const ValueKey<String>('cancel-note-import'),
                onPressed: _cancellation?.cancel,
                child: const Text('CANCEL'),
              ),
            )
          else if (_entries.isNotEmpty)
            ListTile(
              key: const ValueKey<String>('note-import-summary'),
              title: Text('$imported imported · $skipped skipped'),
              subtitle: Text(
                _cancelled
                    ? 'Cancelled — notebooks already imported were kept.'
                    : 'Import complete',
              ),
            ),
          for (final NoteImportResultEntry entry in _entries)
            ListTile(
              dense: true,
              leading: Icon(
                entry.kind == NoteImportResultKind.imported
                    ? Icons.check_circle_outline
                    : Icons.warning_amber,
              ),
              title: Text(entry.sourceName),
              subtitle: Text(entry.message),
            ),
        ],
      ),
    );
  }

  Widget _button(String label, _ImportKind kind) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: OutlinedButton(
      onPressed: _running ? null : () => _start(kind),
      child: Text(label),
    ),
  );
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.title,
    required this.subtitle,
    required this.actions,
  });
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(subtitle),
          const SizedBox(height: 8),
          Wrap(children: actions),
        ],
      ),
    ),
  );
}

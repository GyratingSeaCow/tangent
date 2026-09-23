// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Obsidian export (Settings → Export, 2026-09-23): one-shot export of
// every dump and notebook as markdown into the user's storage folder,
// under an "Obsidian Export/" directory an Obsidian vault can index.
//
// Deliberately one-way and lossless-or-honest: what Tangent can express
// in markdown is exported faithfully; what it cannot (ink strokes) is
// declared in the file rather than silently dropped.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_db.dart';
import '../data/notebook_repository.dart';
import '../screens/home/home_screen.dart' show localDbProvider;
import '../data/storage/storage_contract.dart';
import '../data/storage/storage_providers.dart';
import '../models/dump_mode.dart';
import '../models/notebook.dart';

/// One exported file that failed, and why.
class FailedExport {
  const FailedExport({required this.name, required this.reason});

  final String name;
  final String reason;
}

/// What an export run accomplished.
class ExportSummary {
  const ExportSummary({required this.exported, required this.failed});

  final int exported;
  final List<FailedExport> failed;
}

typedef ExportProgress = void Function(int done, int total, String name);

// ── markdown rendering ────────────────────────────────────────────────

/// Quote only when YAML would misread the value: ": " starts a mapping,
/// " #" a comment, and leading indicators change the type. Bare colons
/// (ISO timestamps) are safe and stay unquoted for Obsidian's parser.
String _yamlEscape(String value) {
  final needsQuoting = value.contains(': ') ||
      value.contains(' #') ||
      value.startsWith(RegExp(r'[\[\]{}#&*!|>' "'" r'"%@`\-? ]')) ||
      value.endsWith(' ');
  return needsQuoting ? '"${value.replaceAll('"', r'\"')}"' : value;
}

String _frontmatter(Map<String, String> fields) {
  final buffer = StringBuffer('---\n');
  fields.forEach((key, value) => buffer.writeln('$key: ${_yamlEscape(value)}'));
  buffer.writeln('---');
  return buffer.toString();
}

String _duration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// Markdown for one dump: frontmatter, title heading, transcript body.
String dumpMarkdown({
  required String id,
  required String title,
  required DateTime createdAt,
  required DumpMode mode,
  required int durationSeconds,
  required String? transcript,
}) {
  final type = switch (mode) {
    DumpMode.brainDump => 'brain-dump',
    DumpMode.meeting => 'meeting',
    DumpMode.textNote => 'text-note',
  };
  final head = _frontmatter({
    'tangent-id': id,
    'created': createdAt.toUtc().toIso8601String(),
    'type': type,
    if (mode != DumpMode.textNote) 'duration': _duration(durationSeconds),
    'source': 'tangent',
  });
  final body = (transcript == null || transcript.trim().isEmpty)
      ? '*Not transcribed yet.*'
      : transcript.trim();
  return '$head\n# $title\n\n$body\n';
}

/// Markdown for one notebook: blocks in reading order (y, then x).
///
/// Checkboxes become Obsidian task-list items. Images and ink cannot ride
/// in markdown, so their presence is declared — the reader must never
/// believe an exported page is the whole page when it is not.
String notebookMarkdown(Notebook notebook) {
  final head = _frontmatter({
    'tangent-id': notebook.id,
    'created': notebook.createdAt.toUtc().toIso8601String(),
    'updated': notebook.updatedAt.toUtc().toIso8601String(),
    'type': 'notebook',
    'source': 'tangent',
  });

  final blocks = List<NotebookBlock>.of(notebook.document.blocks);
  double key(NotebookBlock b) => switch (b) {
        NotebookTextBlock(:final y) => y ?? double.maxFinite,
        NotebookCheckboxBlock(:final y) => y ?? double.maxFinite,
        NotebookImageBlock(:final y) => y,
        _ => double.maxFinite,
      };
  blocks.sort((a, b) => key(a).compareTo(key(b)));

  final body = StringBuffer();
  var images = 0;
  for (final block in blocks) {
    switch (block) {
      case NotebookTextBlock(:final text):
        body
          ..writeln(text.trim())
          ..writeln();
      case NotebookCheckboxBlock(:final text, :final checked):
        body.writeln('- [${checked ? 'x' : ' '}] $text');
      case NotebookImageBlock():
        images++;
      default:
        // Unknown/dumpCard blocks carry no exportable text.
        break;
    }
  }

  final notes = <String>[
    if (notebook.ink.strokes.isNotEmpty)
      'This page also contains handwritten ink that markdown cannot carry.',
    if (images > 0)
      'This page also contains $images image${images == 1 ? '' : 's'} '
          'not included in the export.',
  ];
  final tail = notes.isEmpty
      ? ''
      : '\n> [!note]\n${notes.map((n) => '> $n').join('\n')}\n';

  return '$head\n# ${notebook.title}\n\n${body.toString().trimRight()}\n$tail';
}

// ── filenames ─────────────────────────────────────────────────────────

/// "2026-09-23 Title.md", stripped of everything SAF or Obsidian rejects.
String vaultFileName(String title, DateTime createdAt) {
  final date = createdAt.toUtc().toIso8601String().substring(0, 10);
  var clean = title
      .replaceAll(RegExp(r'[/\\:*?"<>|#^\[\]]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.isEmpty) clean = 'Untitled';
  // SAF display names have modest length limits; leave headroom.
  if (clean.length > 80) clean = clean.substring(0, 80).trim();
  return '$date $clean.md';
}

/// Ensures uniqueness within one run: "Name.md", "Name 2.md", "Name 3.md".
String uniqueVaultName(String name, Set<String> taken) {
  if (taken.add(name)) return name;
  final stem = name.substring(0, name.length - 3);
  for (var i = 2;; i++) {
    final candidate = '$stem $i.md';
    if (taken.add(candidate)) return candidate;
  }
}

// ── the run ───────────────────────────────────────────────────────────

/// Exports every dump and every active notebook as markdown into
/// `Obsidian Export/` inside the app's storage folder.
///
/// Same governing rule as bulk import: one failed file never aborts the
/// rest; every failure is named in the summary.
class ObsidianExporter {
  ObsidianExporter({
    required LocalDb db,
    required NotebookRepository notebooks,
    required StorageBackend backend,
    required StorageCatalog catalog,
  })  : _db = db,
        _notebooks = notebooks,
        _backend = backend,
        _catalog = catalog;

  final LocalDb _db;
  final NotebookRepository _notebooks;
  final StorageBackend _backend;
  final StorageCatalog _catalog;

  static const String directoryName = 'Obsidian Export';

  Future<ExportSummary> run({required ExportProgress onProgress}) async {
    final state = await _catalog.watchDefault().first;
    final location = state.location;
    if (location == null || !state.available) {
      return const ExportSummary(
        exported: 0,
        failed: [
          FailedExport(
            name: 'storage folder',
            reason: 'No recordings folder is configured or reachable.',
          ),
        ],
      );
    }

    final dumps = await _allDumps();
    final notebooks = await _notebooks.watchNotebooks().first;
    final total = dumps.length + notebooks.length;

    var exported = 0;
    final failed = <FailedExport>[];
    final taken = <String>{};
    var done = 0;

    for (final dump in dumps) {
      final name = uniqueVaultName(
        vaultFileName(dump.title, dump.createdAt),
        taken,
      );
      onProgress(++done, total, name);
      final markdown = dumpMarkdown(
        id: dump.id,
        title: dump.title,
        createdAt: dump.createdAt,
        mode: DumpMode.fromWire(dump.mode),
        durationSeconds: dump.durationSeconds,
        transcript: dump.transcript,
      );
      final outcome = await _backend
          .publishDocument(location, directoryName, name, markdown, dump.id)
          .result;
      switch (outcome) {
        case Ok<DurableDocument>():
          exported++;
        case Fail<DurableDocument>(:final problem):
          failed.add(FailedExport(name: name, reason: problem.message));
      }
    }

    for (final notebook in notebooks) {
      final name = uniqueVaultName(
        vaultFileName(notebook.title, notebook.createdAt),
        taken,
      );
      onProgress(++done, total, name);
      final outcome = await _backend
          .publishDocument(
            location,
            directoryName,
            name,
            notebookMarkdown(notebook),
            notebook.id,
          )
          .result;
      switch (outcome) {
        case Ok<DurableDocument>():
          exported++;
        case Fail<DurableDocument>(:final problem):
          failed.add(FailedExport(name: name, reason: problem.message));
      }
    }

    return ExportSummary(exported: exported, failed: failed);
  }

  Future<List<DumpRow>> _allDumps() async {
    final rows = <DumpRow>[];
    for (var offset = 0;; offset += 200) {
      final page = await _db.listDumps(limit: 200, offset: offset);
      rows.addAll(page);
      if (page.length < 200) return rows;
    }
  }
}

final obsidianExporterProvider = Provider<ObsidianExporter>((ref) {
  return ObsidianExporter(
    db: ref.watch(localDbProvider),
    notebooks: ref.watch(notebookRepositoryProvider),
    backend: ref.watch(storageBackendProvider),
    catalog: ref.watch(storageCatalogProvider),
  );
});

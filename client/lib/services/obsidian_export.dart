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
import '../screens/settings/settings_screen.dart' show settingsStoreProvider;
import '../data/storage/storage_contract.dart';
import '../data/storage/storage_providers.dart';
import '../models/dump_mode.dart';
import '../models/notebook.dart';
import 'transcript_markdown.dart';
import 'transcript_timings.dart';

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

/// Markdown for one dump: frontmatter, title heading, transcript body.
///
/// Thin wrapper over [transcriptMarkdown] (timestamps off, no summary):
/// the single renderer behind every markdown export since v1.16.0.
String dumpMarkdown({
  required String id,
  required String title,
  required DateTime createdAt,
  required DumpMode mode,
  required int durationSeconds,
  required String? transcript,
}) {
  return transcriptMarkdown(
    dump: DumpRow(
      id: id,
      createdAt: createdAt,
      updatedAt: createdAt,
      mode: mode.wireValue,
      durationSeconds: durationSeconds,
      title: title,
      transcript: transcript,
      audioPath: '',
      audioSizeBytes: 0,
      syncStatus: '',
      syncAttempts: 0,
      transcriptionStatus: '',
      transcriptionAttempt: 0,
    ),
    timings: null,
    options: const TranscriptMarkdownOptions(
      timestamps: false,
      includeSummary: false,
    ),
  );
}

/// Markdown for one notebook: blocks in reading order (y, then x).
///
/// Checkboxes become Obsidian task-list items. Images and ink cannot ride
/// in markdown, so their presence is declared — the reader must never
/// believe an exported page is the whole page when it is not.
String notebookMarkdown(Notebook notebook) {
  final head = yamlFrontmatter({
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
    this.options = const TranscriptMarkdownOptions(),
  })  : _db = db,
        _notebooks = notebooks,
        _backend = backend,
        _catalog = catalog;

  final LocalDb _db;
  final NotebookRepository _notebooks;
  final StorageBackend _backend;
  final StorageCatalog _catalog;

  /// Document shape for every dump (Settings toggles: timestamps off by
  /// default so an existing vault keeps its shape; summary on).
  final TranscriptMarkdownOptions options;

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
      final markdown = transcriptMarkdown(
        dump: dump,
        timings: TranscriptTimings.parse(dump.transcriptTimings),
        options: options,
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

/// Rebuilt whenever either Obsidian switch flips, so the next run uses
/// what the user just chose.
final obsidianExporterProvider = Provider<ObsidianExporter>((ref) {
  return ObsidianExporter(
    db: ref.watch(localDbProvider),
    notebooks: ref.watch(notebookRepositoryProvider),
    backend: ref.watch(storageBackendProvider),
    catalog: ref.watch(storageCatalogProvider),
    options: ref.watch(obsidianMarkdownOptionsProvider),
  );
});

/// The two Settings switches as renderer options. Seeded from the
/// settings store; the section writes both places on every flip.
final obsidianMarkdownOptionsProvider =
    StateProvider<TranscriptMarkdownOptions>((ref) {
  final settings = ref.watch(settingsStoreProvider);
  return TranscriptMarkdownOptions(
    timestamps: settings.obsidianExportTimestamps,
    includeSummary: settings.obsidianExportSummary,
  );
});

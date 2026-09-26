// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-recording "Export Markdown" (v1.16.0 spec §4).
//
// One call for the list and detail screens: render the recording with
// [transcriptMarkdown] (timestamps + summary always on — this is the
// give-me-everything path; the Obsidian toggles shape the vault, not this),
// name the file, then hand it off — share sheet on mobile, Documents +
// system handler on desktop, mirroring the PDF export's split.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/local_db.dart';
import 'desktop_markdown_share.dart';
import 'export_file_name.dart';
import 'transcript_markdown.dart';
import 'transcript_timings.dart';

/// The options the per-recording path always uses (spec §4 [default]).
const TranscriptMarkdownOptions perRecordingMarkdownOptions =
    TranscriptMarkdownOptions(timestamps: true, includeSummary: true);

/// Signature of the one call the screens make.
typedef ExportRecordingMarkdown = Future<MarkdownExportOutcome> Function(
  DumpRow row,
);

/// What happened to the export, for the caller's snackbar.
///
/// `path` is set on desktop (the file lives in Documents); null on mobile,
/// where the share sheet owns the destination. `opened` is false when no
/// handler for `.md` exists — the file still exists, so it is not an error.
class MarkdownExportOutcome {
  const MarkdownExportOutcome({this.path, this.opened = true});

  final String? path;
  final bool opened;

  /// A user-facing line, or null when there is nothing worth saying
  /// (mobile: the share sheet already showed itself).
  String? get message {
    final String? p = path;
    if (p == null) return null;
    return opened ? 'Exported to $p' : 'Exported to $p (no Markdown handler)';
  }
}

/// `<sanitised title or 'recording'>-<yyyyMMdd-HHmm>.md`, same sanitiser as
/// the PDF export. The stamp is the recording's creation time (local), not
/// "now": a re-export of the same recording lands beside the first with the
/// same stem, and the desktop writer's collision suffix keeps both.
String markdownExportFileName(DumpRow row, {DateTime? at}) {
  final String stem = safeExportStem(row.title, fallback: 'recording');
  final DateTime when = (at ?? row.createdAt).toLocal();
  return '$stem-${DateFormat('yyyyMMdd-HHmm').format(when)}.md';
}

/// Whether the ⋮ menu should offer Export Markdown for [row]: only when
/// there is transcript text to export (absent, not disabled, otherwise).
bool canExportMarkdown(DumpRow row) =>
    (row.transcript?.trim().isNotEmpty ?? false);

/// Renders [row] to Markdown. Pure; shared by both platform branches.
String renderRecordingMarkdown(DumpRow row) => transcriptMarkdown(
      dump: row,
      timings: TranscriptTimings.parse(row.transcriptTimings),
      options: perRecordingMarkdownOptions,
    );

/// Production export: desktop writes to Documents and opens the file;
/// mobile writes to the temp dir and opens the share sheet.
Future<MarkdownExportOutcome> exportRecordingMarkdown(
  DumpRow row, {
  DesktopMarkdownShare? desktopShare,
  bool? desktop,
}) async {
  final String markdown = renderRecordingMarkdown(row);
  final String filename = markdownExportFileName(row);
  final bool onDesktop = desktop ?? (Platform.isLinux || Platform.isWindows);
  if (onDesktop) {
    final DesktopMarkdownShareResult result =
        await (desktopShare ?? DesktopMarkdownShare()).shareMarkdown(
      markdown: markdown,
      filename: filename,
    );
    return MarkdownExportOutcome(path: result.path, opened: result.opened);
  }
  final Directory directory = await getTemporaryDirectory();
  final File file = File('${directory.path}/$filename');
  await file.writeAsString(markdown, flush: true);
  await Share.shareXFiles(
    <XFile>[XFile(file.path, mimeType: 'text/markdown')],
    subject: row.title.isEmpty ? 'Recording' : row.title,
  );
  return const MarkdownExportOutcome();
}

/// The one seam the screens call. Tests override it with a recorder.
final Provider<ExportRecordingMarkdown> exportMarkdownProvider =
    Provider<ExportRecordingMarkdown>((_) => exportRecordingMarkdown);

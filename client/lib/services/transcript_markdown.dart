// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Timestamped Markdown export (v1.16.0,
// docs/design/2026-09-26-timestamped-markdown-export.md §2).
//
// ONE pure renderer for a dump as a markdown document — the Obsidian batch
// export and the per-recording "Export Markdown" action both go through
// [transcriptMarkdown]. No Flutter, no storage, no DB: everything is a
// function of the row, its parsed timings, and the options, so the rules
// (h:mm:ss promotion, speaker-name resolution, summary gating) unit-test
// without fixtures.

import '../data/local_db.dart';
import '../models/dump_mode.dart';
import 'speaker_naming.dart';
import 'transcript_timings.dart';

/// What the caller wants in the document (spec decisions E1 / E3).
class TranscriptMarkdownOptions {
  const TranscriptMarkdownOptions({
    this.timestamps = false,
    this.includeSummary = true,
  });

  /// E1: one `[mm:ss] Name: text` line per timing segment.
  final bool timestamps;

  /// E3: a `## Summary` section when the dump carries a real summary.
  final bool includeSummary;

  @override
  bool operator ==(Object other) =>
      other is TranscriptMarkdownOptions &&
      other.timestamps == timestamps &&
      other.includeSummary == includeSummary;

  @override
  int get hashCode => Object.hash(timestamps, includeSummary);

  @override
  String toString() => 'TranscriptMarkdownOptions('
      'timestamps: $timestamps, includeSummary: $includeSummary)';
}

// ── YAML frontmatter ──────────────────────────────────────────────────

/// Quote only when YAML would misread the value: ": " starts a mapping,
/// " #" a comment, and leading indicators change the type. Bare colons
/// (ISO timestamps) are safe and stay unquoted for Obsidian's parser.
String yamlEscape(String value) {
  final needsQuoting = value.contains(': ') ||
      value.contains(' #') ||
      value.startsWith(RegExp(r'[\[\]{}#&*!|>' "'" r'"%@`\-? ]')) ||
      value.endsWith(' ');
  return needsQuoting ? '"${value.replaceAll('"', r'\"')}"' : value;
}

/// `---` block. A [String] value renders as `key: value`; a
/// `List<String>` as a YAML block sequence. Insertion order is kept.
String yamlFrontmatter(Map<String, Object> fields) {
  final buffer = StringBuffer('---\n');
  fields.forEach((key, value) {
    switch (value) {
      case List<String> items:
        buffer.writeln('$key:');
        for (final item in items) {
          buffer.writeln('  - ${yamlEscape(item)}');
        }
      default:
        buffer.writeln('$key: ${yamlEscape(value.toString())}');
    }
  });
  buffer.writeln('---');
  return buffer.toString();
}

/// Frontmatter `duration:` — always `h:mm:ss`.
String formatDurationField(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return '$h:${_two(m)}:${_two(s)}';
}

String _two(int n) => n.toString().padLeft(2, '0');

// ── timestamps ────────────────────────────────────────────────────────

/// `[mm:ss]` or, when [hours] is set, `[h:mm:ss]`. [seconds] is floored.
/// The caller decides [hours] ONCE for the whole document (E1): a file
/// never mixes the two widths.
String formatSegmentStamp(double seconds, {required bool hours}) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return hours ? '[$h:${_two(m)}:${_two(s)}]' : '[${_two(h * 60 + m)}:${_two(s)}]';
}

/// True when any segment starts at or past one hour — the whole document
/// then promotes to `[h:mm:ss]`.
bool needsHourStamps(TranscriptTimings timings) =>
    timings.segments.any((s) => s.start.floor() >= 3600);

// ── speaker names ─────────────────────────────────────────────────────

/// Timings only know `Speaker N`; the user's names live in the transcript
/// TEXT as `## <name>` headings (v1.15.0, no name map). The meeting
/// formatter numbers speakers by first appearance and writes their
/// sections in that order, so heading k ⇔ the k-th distinct label.
///
/// Returns `label → name`. When the heading count differs from the
/// timings' distinct-label count (the user edited headings) every label
/// maps to itself — never guess. `[unattributed]` and section headings
/// are never paired.
Map<String, String> resolveSpeakerNames({
  required String? transcript,
  required TranscriptTimings timings,
}) {
  final labels = <String>[];
  for (final segment in timings.segments) {
    final speaker = segment.speaker;
    if (speaker != null && !labels.contains(speaker)) labels.add(speaker);
  }
  final identity = {for (final l in labels) l: l};
  if (labels.isEmpty || transcript == null) return identity;
  final headings = speakerHeadings(transcript);
  if (headings.length != labels.length) return identity;
  return {for (var i = 0; i < labels.length; i++) labels[i]: headings[i]};
}

// ── the document ──────────────────────────────────────────────────────

/// Full document per E3: frontmatter, `# title`, `## Summary` when
/// present and wanted, then the transcript.
///
/// Frontmatter keys, in this order, omitted when they do not apply:
/// tangent-id, title, created (UTC ISO), type, duration (h:mm:ss),
/// speakers (resolved names, first-appearance order), summary-template,
/// timestamps ("segments" | "none"), source.
///
/// Transcript rules:
/// - timestamps on + timings: one line per segment, `[mm:ss] Name: text`
///   (or `[mm:ss] text` without a speaker); blank segments skipped;
///   `[h:mm:ss]` for every line once any segment is ≥ 1 h.
/// - timestamps on, no timings: raw text and `timestamps: none`.
/// - timestamps off: raw text, no `timestamps` key.
/// - text notes never get timestamps; the body is the note text.
String transcriptMarkdown({
  required DumpRow dump,
  required TranscriptTimings? timings,
  required TranscriptMarkdownOptions options,
}) {
  final mode = DumpMode.fromWire(dump.mode);
  final isTextNote = mode == DumpMode.textNote;
  final type = switch (mode) {
    DumpMode.brainDump => 'brain-dump',
    DumpMode.meeting => 'meeting',
    DumpMode.textNote => 'text-note',
  };
  final transcript = dump.transcript;
  final hasText = transcript != null && transcript.trim().isNotEmpty;

  final summary = _usableSummary(dump.summary);
  final withSummary = options.includeSummary && summary != null;

  final stamped = !isTextNote && options.timestamps && timings != null;
  // Legacy vault shape: with BOTH options off the document is byte-identical
  // to the pre-1.16.0 `dumpMarkdown` output (no title key, no speakers key,
  // no `## Transcript` heading), so an existing Obsidian vault does not
  // change shape until the user opts in.
  final legacy = !options.timestamps && !options.includeSummary;
  final names = stamped
      ? resolveSpeakerNames(transcript: transcript, timings: timings)
      : const <String, String>{};
  final speakers = legacy
      ? const <String>[]
      : stamped
          ? names.values.toList()
          : hasText
              ? speakerHeadings(transcript)
              : const <String>[];

  final head = yamlFrontmatter({
    'tangent-id': dump.id,
    if (!legacy) 'title': dump.title,
    'created': dump.createdAt.toUtc().toIso8601String(),
    'type': type,
    if (!isTextNote) 'duration': formatDurationField(dump.durationSeconds),
    if (speakers.isNotEmpty) 'speakers': speakers,
    if (withSummary && dump.summaryTemplate != null)
      'summary-template': dump.summaryTemplate!,
    if (!isTextNote && options.timestamps)
      'timestamps': stamped ? 'segments' : 'none',
    'source': 'tangent',
  });

  final String body;
  if (stamped) {
    final hours = needsHourStamps(timings);
    final lines = <String>[];
    for (final segment in timings.segments) {
      final text = segment.text.trim();
      if (text.isEmpty) continue;
      final stamp = formatSegmentStamp(segment.start, hours: hours);
      final speaker = segment.speaker;
      lines.add(
        speaker == null ? '$stamp $text' : '$stamp ${names[speaker]}: $text',
      );
    }
    body = lines.isEmpty ? '*Not transcribed yet.*' : lines.join('\n');
  } else {
    body = hasText ? transcript.trim() : '*Not transcribed yet.*';
  }

  final sections = StringBuffer()..write('$head\n# ${dump.title}\n\n');
  if (withSummary) sections.write('## Summary\n\n$summary\n\n');
  if (!isTextNote && !legacy) sections.write('## Transcript\n\n');
  sections.write('$body\n');
  return sections.toString();
}

/// The summary text worth exporting, or null: blank and the literal
/// `None` (the v1.13.0 actions-only all-None case) both mean "no summary".
String? _usableSummary(String? summary) {
  if (summary == null) return null;
  final text = summary.trim();
  if (text.isEmpty || text == 'None') return null;
  return text;
}

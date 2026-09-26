# Timestamped Markdown export — v1.16.0

Decisions (Jeff, 2026-09-26): **E1=a** segment-level `[mm:ss] Name: text`
(`[h:mm:ss]` past an hour); timestamped paragraphs when there are no
speakers · **E2=a** BOTH an "Include timestamps" toggle on the Obsidian
batch export AND a per-recording ⋮ → "Export Markdown" (Android share
sheet / desktop save + open) · **E3=y** frontmatter + `## Summary` when
present + `## Transcript`.

Defaults taken while Jeff was away are marked **[default]**.

## 1. What exists

- `client/lib/services/obsidian_export.dart`: `dumpMarkdown({id, title,
  createdAt, mode, durationSeconds, transcript})` renders frontmatter +
  `# title` + raw transcript; `ObsidianExporter.run()` walks every dump and
  notebook into the vault folder. Settings section:
  `screens/settings/obsidian_export_section.dart`.
- `client/lib/services/transcript_timings.dart`: `TranscriptTimings.parse(raw)`
  → `segments[] {start, end, speaker, text, words}` (server-owned column on
  every transcribed dump since v1.12.0).
- Per-item share/PDF already exists: `ItemAction.share` / `ItemAction.exportPdf`
  in `dumps_list_screen.dart` (~651), `share_plus` on mobile,
  `services/desktop_pdf_share.dart` on desktop (writes to Documents + opens
  with the system handler; both steps injectable).
- Speaker names (v1.15.0) live in the transcript TEXT (`## Jeff` headings),
  NOT in `transcript_timings.segments[].speaker` (still `Speaker N`).

## 2. Pure function — `lib/services/transcript_markdown.dart`

```dart
class TranscriptMarkdownOptions {
  final bool timestamps;      // E1
  final bool includeSummary;  // E3, default true
}

/// Full document per E3. Frontmatter keys (in this order, omitted when
/// null): tangent-id, title, created (UTC ISO), type, duration (h:mm:ss),
/// speakers (YAML list; names resolved as below), summary-template,
/// timestamps ("segments" | "none"), source: tangent.
String transcriptMarkdown({
  required DumpRow dump,               // id/title/createdAt/mode/duration/
                                       // transcript/summary/summaryTemplate
  required TranscriptTimings? timings,
  required TranscriptMarkdownOptions options,
});
```

Body rules:
- `## Summary` + summary text, only when `options.includeSummary` and the
  summary is non-blank and not the literal `None`. [default: the v1.13.0
  all-`None` actions-only case is treated as no summary]
- `## Transcript`:
  - **timestamps=true AND timings present**: one line per segment,
    `[mm:ss] Name: text` when the segment has a speaker, `[mm:ss] text`
    when not. Timestamps from `segment.start`, floored to the second,
    `[h:mm:ss]` once ≥ 3600 s (per E1 — never mixed within one document:
    if ANY segment is ≥ 1 h, all use `h:mm:ss`) [default]. Blank
    segment text is skipped.
  - **timestamps=true but no timings**: the raw transcript text, and
    frontmatter `timestamps: none`.
  - **timestamps=false**: the raw transcript text (byte-identical to
    today's `dumpMarkdown` body), frontmatter `timestamps` key omitted.
- Speaker **name resolution** [default]: timings only know `Speaker N`.
  Build the map `Speaker N → name` by pairing `## <heading>` lines in the
  transcript text with `Speaker N` labels **in order of first appearance**
  (the formatter numbers speakers by first appearance, so heading k in
  document order ⇔ `Speaker k`). Headings equal to `Speaker N` map to
  themselves; `[unattributed]` is never paired. If the heading count
  differs from the timings' distinct-speaker count (user edited headings),
  fall back to the raw `Speaker N` labels — never guess.
- `speakers:` frontmatter lists the resolved names in first-appearance
  order; omitted when there are none.
- Text notes (`mode == textNote`) never get timestamps; the body is the
  note text.

`dumpMarkdown` is kept as a thin wrapper (`timestamps=false,
includeSummary=false`) so existing Obsidian-export tests stay byte-exact.

## 3. Obsidian batch toggle (E2 part 1)

- Settings → Obsidian export section: `SwitchListTile` keyed
  `obsidian-timestamps` "Include timestamps" (subtitle "One line per
  transcript segment, `[mm:ss] Name: text`"), persisted in the existing
  settings store under `obsidianExportTimestamps` (default **off** so
  existing vaults don't change shape on the next run) [default]. A second
  switch keyed `obsidian-summary` "Include summary" default **on**
  [default: E3 applies to both paths].
- `ObsidianExporter` gains `TranscriptMarkdownOptions options` and passes
  the dump's parsed timings + summary into `transcriptMarkdown`.

## 4. Per-recording export (E2 part 2)

- `ItemAction.exportMarkdown` "Export Markdown" with `Icons.description`,
  placed right after `exportPdf`; absent for text notes with empty text
  and for recordings with no transcript (absent, not disabled). Always uses
  `timestamps: true, includeSummary: true` [default — the per-recording
  path is the "give me everything" path; the Obsidian toggles are for vault
  shape].
- File name: `<sanitised title or 'recording'>-<yyyyMMdd-HHmm>.md`, same
  sanitiser the PDF exporter uses.
- Mobile: `share_plus` `shareXFiles` with `text/markdown`.
  Desktop: a `DesktopMarkdownShare` mirroring `DesktopPdfShare` (write to
  Documents, open with the system handler; injectable writer/opener).
  Both behind one `exportMarkdownProvider` so the list screen has one call.
- Detail screen: same action inside the `detail-more` overflow added in
  v1.15.0 (now two entries when both apply).

## 5. Tests (minimum)

Unit `test/unit/services/transcript_markdown_test.dart`:
- timestamps formatting (`[00:05]`, `[1:02:03]` promotion for the whole
  doc), speaker line vs plain line, blank segments skipped;
- name resolution: headings pair with `Speaker N` by order; mismatch count
  → raw labels; `[unattributed]` ignored;
- summary section present/absent (blank, `None`, includeSummary=false);
- no timings + timestamps=true → raw body + `timestamps: none`;
- text note → no timestamps regardless;
- `dumpMarkdown` wrapper byte-identical to the current output (pin with a
  golden string from the existing test).

Widget:
- Obsidian section: both switches persist; exporter receives the options.
- List ⋮: "Export Markdown" present for a transcribed recording, absent for
  an untranscribed one; picking it calls the provider with the row.
- Desktop share: writes the file and calls the opener (fake both).

Sabotage proofs: (1) break the h:mm:ss promotion (always mm:ss) → unit
fails; (2) pair headings with speakers by *last* appearance → resolution
test fails; (3) orchestrator's pick.

## 6. Out of scope (logged)

Word-level inline timestamps (E1=b), notebook export changes, HTML/PDF
transcript export, export of audio alongside.

## 7. Release

Client-only. Same 7 version files + CHANGELOG + `docs/next-iteration.md`
§1.14. Container rebuilt to keep the version uniform (same call as
v1.15.0).

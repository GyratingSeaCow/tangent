# Recordings rename + meeting-capture removal — v1.22.0

Date: 2026-09-27 · Status: approved (Jeff's picks recorded below)

## Decisions (Jeff, 2026-09-27)

- **R1 — "Dumps" → "Recordings" in every user-visible string.** Display
  strings ONLY: internal identifiers, Drift/SQL tables, file names,
  `/v1/dumps` API paths, keys, and the `Dump` model name all stay — same
  discipline as the v1.8.0 app-name capitalization (renaming wire/DB
  surfaces churns sync for zero user benefit).
- **R2 — the capture MODE stays named "Brain Dump"** (list surfaces say
  Recordings; the mode chip/label keeps its name).
- **M1 — Meeting capture is REMOVED everywhere**: the home screen's
  three-way mode picker loses Meeting, and the recordings list's create
  menu loses its Meeting action. Existing meeting recordings keep their
  mode, rendering, and features unchanged — only the ways to create NEW
  meeting-mode recordings go away. Rationale: summaries / action items /
  speaker naming are all reachable on any recording via the
  transcription + summarize flow now.

## R1 — rename surfaces (display strings only)

Sweep `client/lib` for user-visible dump/Dump strings; the verified hit
list (grep before editing — more may exist):

- `dumps_list_screen.dart`: AppBar title 'Dumps' → 'Recordings'; search
  hint 'Search dumps…' → 'Search recordings…'; empty state 'No dumps
  yet — record one!' → 'No recordings yet — record one!'.
- `home_screen.dart`: tooltip 'View dumps' → 'Recordings'.
- `notebook_editor_screen.dart` insert menu: 'Dump' item label →
  'Recording' (the audio-card insert).
- `settings/bulk_import_section.dart`: '…becomes a normal brain dump…'
  — keep "brain dump" HERE (it names the mode, R2) but read the
  sentence and fix only if it references the list/section.
- `settings/obsidian_export_section.dart`: 'Writes every brain dump and
  notebook…' → 'Writes every recording and notebook…' (this one is the
  collection, not the mode).
- Error/snackbar strings that say 'dump' where a user reads them.
  StateError/log-only strings (repository internals) stay.
- Screen-reader semantics (`semanticLabel`, `message:`) count as
  user-visible.

NOT renamed: `DumpMode.brainDump` label 'Brain Dump' (R2), all `dump`
identifiers/keys/tests-by-key, `docs/` history, CHANGELOG back-entries.

Mode descriptions on the home picker: the text-note line 'Type a quick
note — searchable with your dumps.' → '…searchable with your
recordings.'

## M1 — meeting capture removal

- `home_screen.dart`: the `SegmentedButton`/picker loses the
  `DumpMode.meeting` segment (Brain Dump | Note remain; if only two
  segments look odd, they stay a segmented control anyway — no redesign
  in this arc). The meeting mode-description line goes.
- `dumps_list_screen.dart`: `DumpsCreateAction.meeting` and its menu
  item are removed; the enum case is deleted (analyzer will name every
  switch that must shed the case — follow non_exhaustive_switch).
- `DumpMode.meeting` itself STAYS in the enum/wire (existing recordings
  deserialize it; detail/list render meeting rows exactly as today,
  MeetingNotesProcessor untouched).
- Guard: nothing else may construct `DumpMode.meeting` for a NEW
  recording — grep for `DumpMode.meeting` constructions on create paths
  and pin with a test that the create surfaces offer exactly
  {brain dump, note}.

## Tests

- Widget: recordings list shows 'Recordings' title, renamed hint/empty
  state; home tooltip renamed; home picker has NO Meeting segment; list
  create menu has NO meeting action; an EXISTING meeting-mode row still
  renders its meeting affordances (regression pin).
- Update existing tests that pinned the old strings/segments honestly.

## Sabotage (named)

- (a) Re-add the Meeting segment to the home picker → the picker test
  fails, quote, restore, re-pass.
- (b) Revert the list title to 'Dumps' → the title test fails.

## Proof before merge (device)

Home screen: picker shows Brain Dump | Note only; recordings icon
tooltip reads Recordings; list titled Recordings; an old meeting
recording opens with summary/notes intact.

## Versioning / release

Client-only; rides the v1.22.0 train with page-backgrounds (already in
flight on feature/page-backgrounds). Separate branch, merged after it.

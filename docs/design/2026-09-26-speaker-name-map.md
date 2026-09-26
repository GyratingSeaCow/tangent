# Speaker name map — v1.17.0

Decisions (Jeff, 2026-09-26): **N1=a** names live ONLY in a per-recording
map; transcript text keeps raw `## Speaker N`; every surface renders names
by look-up · **N2=y** re-transcribe keeps names automatically (warning line
removed) · **N3=y** rename once on a recording → Listen, export, summary all
show it (per recording, never global).

Supersedes the v1.15.0 rewrite-in-place (S1=b). Defaults taken while Jeff
was away are marked **[default]**.

## 1. Data

- Column `dumps.speaker_names TEXT` (JSON object `{"Speaker 1":"Jeff",
  "Speaker 2":"Sarah"}`; null/absent = no names) on **both** server and
  client. Device-authored (edited on a device, synced up, fanned out) —
  it competes on `updated_at` like `title`, NOT the server-authored bypass.
- Client DB **v20**: `addColumn(dumps, speakerNames)`; nullable
  `TextColumn get speakerNames`. Sync: `speaker_names` rides the push payload
  next to `title`/`transcript`; on pull, absent-vs-null sentinel (absent =
  leave alone, present null = cleared) — same contract as `summary_template`.
- Server: `_migrate_dumps_speaker_names` adds the column; sync upsert
  `val("speaker_names")`; publish includes it; `DumpResponse.speaker_names`.
- Pure model `SpeakerNames` (`client/lib/models/speaker_names.dart`):
  `fromJson/toJson`, `nameFor(label) → label` (falls back to the raw label),
  `withRename(label, name)` (blank name = remove key), `isEmpty`.

## 2. One-time back-fill (the 1.15.0 rewrite)

On client migration to v20, for every dump whose transcript has a `## `
heading that is neither `Speaker N` nor `[unattributed]` nor a known
section heading (`hasUserSpeakerNames` from v1.15.0):
1. pair headings with `Speaker N` by document order (heading k ⇔
   `Speaker k`, same rule the export uses),
2. write `speaker_names = {"Speaker k": heading}`,
3. rewrite each `## <name>` heading back to `## Speaker k` and
   `<name>: ` turn prefixes back to `Speaker k: ` (the inverse of
   `applySpeakerNames`),
4. mark the dump for push (`sync_status` dirty) so the server and other
   devices converge.
Idempotent (second run finds no user headings). Tested on an old-schema
fixture DB **and** against a copy of the live Windows DB (`.backup()`
snapshot — 11 diarized dumps, N renamed) with counts asserted. [default —
nothing is deleted; a `speaker_names_backfill` row in the client's
`settings` table records what was rewritten, for a one-shot undo if ever
needed.]

## 3. Rendering (look-up everywhere)

`String renderSpeakerNames(String transcript, SpeakerNames names)` —
replaces `## Speaker N` headings and line-leading `Speaker N: ` prefixes
with the mapped name; prose untouched; pure; the inverse is not needed
because the stored text is never derived from the rendered text.

Surfaces (each gets a test asserting the name appears):
- **Detail / Edit mode**: the editor shows the RENDERED text. On Save, the
  reverse map is applied (`## Jeff` → `## Speaker 1`) before persisting,
  using the CURRENT map; a heading the user typed that matches no name is
  left as typed. [default — keeps Edit WYSIWYG without storing names]
- **Listen mode**: `listen_transcript_view.dart` header shows
  `names.nameFor(segment.speaker)`.
- **List cards / search snippets**: `dumpSubtitle` and snippet runs pass
  through `renderSpeakerNames`.
- **Export** (`transcript_markdown.dart`): `resolveSpeakerNames` now takes
  the map first; heading-order pairing remains only as the fallback for
  dumps with no map. `speakers:` frontmatter from the map.
- **Summaries** (server): `summarize_dump` renders the transcript through
  the map before `infer(...)` so the model sees names. `assemble_prompt`
  unchanged; the 409 detail strings unchanged.
- **Meeting notes** (`meeting_notes`, server secretary) — unchanged; it
  is regenerated from segments and shows raw labels. [default: out of
  scope; logged]

## 4. Sheet + entry points (v1.15.0 reused)

`NameSpeakersSheet` prefills each field with the CURRENT mapped name
(empty when unmapped) and Save writes the **map** (`LocalDb.updateSpeakerNames
(id, names)` → bumps `updated_at`, marks dirty for push). It no longer
touches the transcript text. Collision rules unchanged. Suggestion chips
now come from `speaker_names` values across dumps (newest first, max 8)
instead of headings. Entry points (list ⋮, `detail-more`, Listen header
tap) unchanged.

Re-transcribe: the "Speaker names you added will be reset." line and its
`hasUserSpeakerNames` gate are removed; the new transcript's raw labels
render through the existing map. Re-transcribe warning tests are inverted
(line must be absent).

## 5. Tests (minimum)

- `speaker_names_test.dart`: model round-trip, nameFor fallback,
  withRename blank removes.
- `render_speaker_names_test.dart`: headings + prefixes, prose untouched,
  unmapped labels pass through, reverse map on Edit save.
- Migration: old-schema fixture with a renamed dump → v20 has the map and
  raw headings; idempotent second run; sync dirty flag set.
- Sync: push payload carries `speaker_names`; pull absent leaves alone,
  present null clears; server upsert + publish round-trip (server pytest).
- Server summarizer: names substituted before infer; Meeting prompt drift
  guard unchanged.
- Widgets: Listen header shows name; export uses map over headings; sheet
  prefills and saves the map (transcript text unchanged — assert
  byte-equal); re-transcribe dialog line absent.

Sabotage proofs required: (1) `renderSpeakerNames` skips turn prefixes →
render test fails; (2) migration writes the map but forgets to revert the
headings → idempotence test fails; (3) server summarizer skips the
substitution → names-in-prompt test fails; (4) orchestrator's pick.

## 6. Out of scope (logged)

Global name book / voice matching, meeting-notes digest renaming, renaming
`[unattributed]`.

## 7. Release

Server + client. Client DB v20, server migration, container rebuild, APK to
all three devices, GitHub release. Same 7 version files + CHANGELOG +
`docs/next-iteration.md` §1.15.

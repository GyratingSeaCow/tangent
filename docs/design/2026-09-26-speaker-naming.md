# Speaker naming — v1.15.0

Decisions (Jeff, 2026-09-26): **S1=b** rewrite the transcript text in place
(no name map; Listen mode keeps the raw `Speaker N` from timings; a
re-transcribe wipes names — both accepted) · **S2=a** ⋮ "Name speakers"
sheet AND tapping a speaker header in Listen mode opens the same sheet ·
**S3=y** tap-to-fill chips of names used on other recordings (never
auto-applied, no voice matching) · **S4** moot under S1=b — the summarizer
already reads the transcript text, so summaries get names for free ·
**S5=a** own release.

Defaults taken while Jeff was away are marked **[default]**.

## 1. What exists

- Diarized transcripts are rendered by `formatMeetingTranscript`
  (`client/lib/services/meeting_transcript_formatter.dart`, byte-lockstep
  with `server/app/services/secretary.py::format_meeting_transcript`):
  `## Speaker N` sections ordered by first appearance, optional final
  `## [unattributed]`. Live DB has 11 such dumps.
- `transcript_timings.segments[].speaker` carries the same `Speaker N`
  labels (Listen mode groups by it, `listen_transcript_view.dart` ~264-295).
- Transcript edits persist via `LocalDb.updateDumpTranscript(id, storageKey,
  expected*, transcript)` (optimistic concurrency) and sync as a device-
  authored change. **This arc is client-only. No server change, no DB
  migration, no container rebuild.**

## 2. Pure function — `lib/services/speaker_naming.dart`

```dart
/// Speaker labels present in [transcript], in document order.
/// Matches `## Speaker N` headings only; `[unattributed]` is never a speaker.
List<String> detectSpeakers(String transcript);

/// First non-empty line under each `## <label>` heading — the hint shown
/// beside the field ("Ended up getting fired and…", ellipsised at 80 chars).
Map<String, String> firstLineBySpeaker(String transcript);

/// Rewrites [transcript] applying [renames] (old label → new name).
/// - Replaces the `## Old` heading line (exact) with `## New`.
/// - Replaces inline whole-word `Old:` turn prefixes (`^Old: ` at line start)
///   with `New: ` — covers the timestamped-paragraph fallback and any
///   hand-typed turns. Never touches `Old` inside prose. [default]
/// - Empty / whitespace new name ⇒ that speaker is left unchanged.
/// - Trims names; collapses internal runs of whitespace to one space.
/// - Idempotent; returns [transcript] unchanged when nothing applies.
String applySpeakerNames(String transcript, Map<String, String> renames);

/// Names a user has typed before: every `## <heading>` across [transcripts]
/// that is not `Speaker N`, `[unattributed]`, or a known section heading
/// (`Meeting Summary`, `Action Items`, `Transcript`, `Summary`); most-
/// recently-seen first (caller passes newest transcript first); max 8;
/// case-exact dedupe. [default]
List<String> suggestedSpeakerNames(Iterable<String> transcriptsNewestFirst);
```

Collision rule [default]: two speakers may not be given the same name in one
sheet; the Save button disables and the second field shows "Already used".
Renaming a speaker to a name that is *already a heading in the transcript*
(user typed `Speaker 2` for Speaker 1, say) is also refused the same way.

## 3. Sheet — `lib/screens/dump/name_speakers_sheet.dart`

`Future<bool> showNameSpeakersSheet(BuildContext, WidgetRef, DumpRow)` →
true when a rename was saved.

- Title "Name speakers". One row per `detectSpeakers` result, in order:
  label `Speaker N` (key `speaker-label-<n>`), `TextField` keyed
  `speaker-name-<n>` prefilled EMPTY (hint text = current label), helper
  line = `firstLineBySpeaker` hint keyed `speaker-hint-<n>`.
- Chip row keyed `speaker-suggestions` (hidden when empty): tapping a chip
  fills the **focused** field, or the first empty field when none is focused.
  [default]
- **Save** keyed `speakers-save`: enabled iff ≥1 non-empty field and no
  collisions. Calls `applySpeakerNames`, then `updateDumpTranscript` with
  the row's current `transcript` / attempt / requestId as the expected
  values. On `StaleTranscript`-style conflict: snackbar "Transcript changed
  underneath you — reopen and try again", sheet stays open. On success
  snackbar "Speakers named".
- Cancel = pop with false. No autosave.
- Suggestion source: `ref.read(localDbProvider).recentTranscriptsForSpeakerSuggestions(limit: 50)`
  — a new tiny DB query (`SELECT transcript FROM dumps WHERE deleted_at IS
  NULL AND transcript LIKE '%## %' ORDER BY updated_at DESC LIMIT 50`). Read-
  only, no schema.
- Absent, not disabled, when `detectSpeakers` is empty (dumps-ui-conventions).

## 4. Entry points

1. **List ⋮ sheet** (`dumps_list_screen.dart::_showItemActions`, enum
   `ItemAction`): new `ItemAction.nameSpeakers` "Name speakers" with
   `Icons.record_voice_over`, shown only when the row's transcript has
   speakers (absent otherwise), placed directly after `rename`.
2. **Detail screen**: same action in the detail app-bar overflow (there is
   no overflow today — add a `PopupMenuButton` keyed `detail-more` with
   this single entry; absent when no speakers). [default — keeps the
   existing icon row untouched]
3. **Listen mode**: each speaker header `Text` in `listen_transcript_view.dart`
   (~line 288) becomes an `InkWell` keyed `listen-speaker-header-<label>`
   whose `onTap` calls a new optional `onSpeakerTap(String label)` callback;
   `dump_detail_screen.dart` wires it to open the sheet. Listen mode keeps
   showing the raw timings label after a rename (S1=b — documented in the
   sheet's helper text: "Listen mode keeps the original speaker labels").

## 5. Re-transcribe warning [default]

The existing "Overwrite transcript?" dialog (`dump_detail_screen.dart` ~726)
gets one extra content line **only when** `detectSpeakers(transcript)` is
non-empty AND the transcript contains a heading that is not `Speaker N`:
"Speaker names you added will be reset." Test pins both branches.

## 6. Tests (minimum)

Unit `test/unit/services/speaker_naming_test.dart`:
- detectSpeakers: order, ignores `[unattributed]` and non-speaker headings,
  empty on plain transcripts.
- firstLineBySpeaker: first non-empty line, 80-char ellipsis.
- applySpeakerNames: heading + `Old:` prefix rewrite; prose untouched
  (`"I told Speaker 1 to wait"` stays); blank ⇒ unchanged; whitespace
  normalisation; idempotent; unknown label ignored.
- suggestedSpeakerNames: filters, newest-first order, max 8, dedupe.

Widget `test/widget/name_speakers_sheet_test.dart`:
- Rows/hints from a two-speaker transcript; chips from seeded transcripts;
  chip fills focused field; Save disabled until a field is filled; collision
  disables Save with "Already used"; Save writes rewritten transcript via
  the real LocalDb (StorageFixture, `fixture-` ids) and pops true; stale
  transcript ⇒ snackbar, sheet stays.

Widget touches:
- list ⋮ shows "Name speakers" only for diarized rows;
- detail overflow present/absent;
- Listen header tap invokes `onSpeakerTap` with the label;
- re-transcribe dialog line present/absent.

Sabotage proofs required: (1) make `applySpeakerNames` also replace the
label inside prose → prose test fails; (2) drop the collision check →
"Already used" widget test fails; (3) the orchestrator's own pick.

## 7. Out of scope (logged)

Name map / re-apply after re-transcribe (S1=c), Listen-mode renamed labels,
voice matching across recordings, server-side awareness of names.

## 8. Release

Client-only. Same 7 version files + CHANGELOG + `docs/next-iteration.md`
§1.13. `server/app/version.py` + compose + pyproject still bump so the
version stays uniform (AGENTS.md rule), but the container is **not**
rebuilt for this release — the image tag simply reads 1.14.0 until
v1.16.0 ships server changes… **[default: rebuild anyway]** — a 10-minute
rebuild is cheaper than a version-string mismatch the next person has to
explain, so the container IS rebuilt to 1.15.0.

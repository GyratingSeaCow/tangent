# Voice matching — remembered voices name speakers automatically

Date: 2026-09-29 · Status: approved (Jeff's picks recorded below)
Builds on: `2026-09-26-speaker-name-map.md` (per-recording `speaker_names`
map, one rename → every surface, re-transcribe keeps names), the server
diarization service (`server/app/services/diarization.py`, pyannote
`speaker-diarization-3.1` on pyannote.audio 4.x).

## Decisions (Jeff, 2026-09-29)

- **V1 — Silent auto-naming.** A new recording whose diarized speakers
  match remembered voices comes back already reading `Jeff:` / `Tom:`;
  no "sounds like Jeff — apply?" prompt. Consequence: the acceptance
  threshold is conservative and calibrated on Jeff's own recordings before
  it is locked (see *Calibration*).
- **V2 — A correction teaches the corrected-to name only.** Renaming a
  mis-named speaker to `Dana` remembers Dana's voice; the voice previously
  stored for `Tom` is left alone. No negative examples. Rejected: an
  "is-not" store — real corrections always name the right person.
- **V3 — One shared voice book on the server.** Renaming on any device
  teaches the server; every device's next recording benefits. Settings
  gains a **Voices** list: one row per remembered name, how many
  recordings taught it, and a per-row **Forget**. There is no wipe-all
  control — forget is one name at a time, always.
- **V4 — Approach 1: one centroid per name, threshold match, server-side.**
  Rejected: keeping every sample with k-NN (over-engineered for a
  handful of people; the forget UI would need per-sample rows to be
  honest) and a client-side voice book (three devices would learn
  separately or need a fourth sync entity; the server already has the
  audio and the model).

## What Jeff sees

1. Records a meeting on the Tab. Transcript arrives reading
   `Speaker 1: …` / `Speaker 2: …`. Renames Speaker 1 → **Jeff**,
   Speaker 2 → **Tom** (the existing rename sheet; nothing new).
2. Settings → **Voices** now lists `Jeff · taught by 1 recording`,
   `Tom · taught by 1 recording`.
3. Next week records on the Fold with Tom and a stranger. Transcript
   arrives reading `Jeff:` / `Tom:` / `Speaker 3:`. The recording's name
   map is filled in by the server exactly as if Jeff had renamed them, so
   the summary, export, notes and search all say the names.
4. If the server got one wrong, Jeff renames it as today; the rename
   wins (the map is the device's to edit) and teaches the new name (V2).
5. Settings → Voices → **Forget** on `Tom` removes Tom's voice. Recordings
   already naming Tom keep their names — the map belongs to the
   recording; the book only decides future recordings.

## Where the embedding comes from

pyannote 4.x's `SpeakerDiarization.apply` returns a `DiarizeOutput` whose
`speaker_embeddings` is a `(num_speakers, 256)` array of clustering
centroids aligned with `annotation.labels()` (verified on the running
container, pyannote.audio 4.0.7). No second model pass. The existing
`_extract_turns` already unwraps this object; `diarize_segments` gains a
sibling that also returns `{label: embedding}` keyed by the same raw labels
that `_label_map` turns into `Speaker N`.

Embeddings are L2-normalised before storage; similarity is the dot product
(cosine). Stored as JSON lists of 256 floats — 14 diarized recordings today,
a few KB each; no blob column needed.

## Data model (server only — nothing new crosses the wire except names)

`dumps.speaker_embeddings TEXT` (nullable JSON `{"Speaker 1": [256 floats],
…}`), written by the job runner alongside `transcript_timings` on every
diarized transcription. Server-private: **not** in `_dump_payload`, not in
the sync feed, not in `DumpCreate`/`SyncChange`. Null for recordings
transcribed before this release or without diarization.

New table `voice_book`:

| column | type | notes |
|---|---|---|
| `name` | TEXT PK | the display name exactly as typed (case-sensitive, trimmed) |
| `embedding` | TEXT | JSON list, L2-normalised running mean |
| `samples` | INTEGER | recordings that taught this name |
| `updated_at` | TEXT | RFC3339 |

Migration `_migrate_voice_book` follows `_migrate_dumps_speaker_names`.

## Teaching (on rename)

Trigger: `_apply_dump` in `sync.py` receives a change whose
`speaker_names` differs from the stored value. After the upsert, for every
`(label → name)` pair in the new map where `name` is non-empty and the
label has an embedding in `dumps.speaker_embeddings`:

- if the pair is new or its name changed since the stored map → **teach**
  `name` with that embedding.
- Teach = `voice_book[name]` upsert: `embedding = normalise((old * samples
  + new) / (samples + 1))`, `samples += 1`. First sample = the embedding
  itself.
- Names removed from the map (label unmapped) teach nothing (V2).
- A rename that only re-cases or re-spaces a name is a new name; the book
  stores what was typed. (`Jeff` and `jeff` are two voices — the Voices
  list makes that visible and forgettable.)

A recording auto-named by the server (below) does **not** teach: its map
was written by the matcher, not a person. Only maps that arrive from a
device teach. Implemented by teaching only inside `_apply_dump`, never in
the job runner.

## Matching (on transcription)

In `job_queue.py`, after diarization produces labels and embeddings and
before the dump row is updated:

```
book = load_voice_book(db)            # [] → skip entirely
for each speaker label L with embedding e:
    sims = [(dot(e, b.embedding), b.name) for b in book]
    best, second = top two sims (second = -1.0 if only one name)
    if best >= ACCEPT and (best - second) >= MARGIN: candidate[L] = name
each name may be claimed by at most one label: on conflict the higher
similarity keeps it, the other label stays 'Speaker N'.
```

Result written as the recording's `speaker_names` map (same JSON the
rename feature stores) **only when the stored map is empty/null** — a map
the user already wrote is never overwritten, including on re-transcribe
(the name-map spec's N2 rule stands). Published on the sync feed via the
existing `_publish_dump_change` so every device renders the names.

Constants in `diarization.py`, one place: `VOICE_ACCEPT = 0.60`,
`VOICE_MARGIN = 0.10`, `VOICE_MIN_SPEECH_S = 15.0`. All three set by
calibration on real recordings (below), not guessed.

**Minimum-speech gate.** A speaker who talks for less than
`VOICE_MIN_SPEECH_S` seconds in total across a recording keeps their
`Speaker N` label but carries **no centroid**: never stored, never taught
from a rename, never matched. Centroids from a few seconds of speech are
noise — see the calibration table. Turns are summed per speaker, so a
back-and-forth meeting where nobody holds the floor for 15 s straight
still qualifies.

Log line per recording: `voice_match.applied names=… rejected=[(label,
best_sim, best_name), …]` so a wrong or missed match is diagnosable from
`docker logs` without the embeddings.

## Calibration (before the threshold is locked — part of the plan, not a
follow-up)

A one-off script `server/scripts/voice_calibrate.py` run inside the
container against Jeff's real DB copy:

1. Re-diarize every dump with `audio_kept` (14 today) to get embeddings.
2. Using the one recording that already names `Jeff`, print the cosine
   similarity of every other recording's speakers to Jeff's centroid,
   sorted, with the recording title — Jeff confirms by ear which rows are
   actually him.
3. Report the lowest true-Jeff similarity and the highest non-Jeff
   similarity. `VOICE_ACCEPT` is set at least 0.05 above the highest
   impostor and the gap to the lowest true match is recorded in the spec's
   status line. If the two overlap, the feature ships with a higher
   threshold (misses beat mislabels under V1) and the spec says so.

### Result (2026-09-29, Jeff's library, pyannote 4.0.7)

Running the script is `docker cp server/scripts tangent-server:/app/scripts`
then `docker exec tangent-server python -m scripts.voice_calibrate --name
Jeff` (the image does not ship `scripts/`). The first run on the 128-
recording library found three real-audio defects the unit tests could
not (wrapper vs inner `labels()`, `database is locked` against the live
server, NaN centroids on near-silent clips) — all fixed before the numbers
below were taken.

Almost the whole library was 2–12 s test clips, and on those the scores
overlapped: a confirmed stranger's 6 s clip scored **0.58**, Jeff's own
2.5 s clip **0.38**. Jeff recorded three 22–60 s clips of himself and two
of other people, and with a centroid built from Jeff's ≥ 15 s recordings
only:

| Group | Cosine to "Jeff" centroid |
|---|---|
| Jeff, ≥ 15 s (leave-one-out) | 0.76 – 0.85 (one outlier 0.53) |
| Confirmed not Jeff, ≥ 15 s | −0.04, −0.07 |
| Every other unlabelled speaker ≥ 15 s (all confirmed not Jeff) | ≤ 0.28 |
| Jeff, < 15 s clips | 0.38 – 0.69 |
| Confirmed not Jeff, 6 s clip | 0.58 |

Hence `VOICE_MIN_SPEECH_S = 15.0` (the overlap lives entirely under 15 s)
and `VOICE_ACCEPT = 0.60`: 0.32 above the worst impostor, 0.16 under
Jeff's typical floor. The 0.53 outlier is a miss (stays `Speaker 1`),
which V1 prefers to a wrong name.

## Settings → Voices (client)

- New section `voices_section.dart` under the existing Google/Whisper
  sections: a list of `name · taught by N recording(s)`, newest-updated
  first, each row with a trailing **Forget** icon button. Tapping asks
  `Forget Tom's voice? Recordings already naming Tom keep their names.`
  → Forget / Cancel. No select-all, no "Forget all" (V3).
- Empty state: `No remembered voices yet. Rename a speaker on a recording
  and Tangent will recognise them next time.`
- Section is hidden when the server reports diarization is off. `ServerInfo`
  (`/v1/server/info`) gains `diarization: bool` from
  `is_diarization_enabled()`; an older server omits the field → the client
  treats it as `false` and hides the section.
- API: `GET /v1/voices` → `[{name, samples, updated_at}]`;
  `DELETE /v1/voices/{name}` → 204 (404 if unknown; name is a path
  parameter, URL-encoded; the existing `ENTITY_ID_PATTERN` does **not**
  apply — names have spaces — so the handler looks the name up, never
  builds a path from it). Bearer auth as every other route.

## Out of scope (this arc)

- Prompted "apply?" confirmation (V1 chose silent).
- Negative examples / "this is not Tom" (V2).
- Per-sample history, re-listen to the teaching recording.
- Renaming a voice in the book (rename a speaker on a recording instead;
  the old name stays until forgotten).
- Client-side matching, on-device diarization.
- Back-filling names onto old recordings when a voice is learned.

## Tests

Server (pytest, `-p no:cacheprovider`):
- `test_voice_book.py` — teach math (first sample = embedding; running
  mean re-normalised; `samples` counts); match rules (accept, below
  accept, below margin, one-name-per-recording conflict → higher wins;
  empty book → no map written); stored map never overwritten; auto-named
  recording does not teach; forget removes one row only.
- `test_sync_apply_speaker_names_teach.py` — pushing a map through
  `/v1/sync/push` teaches exactly the changed pairs; unchanged pairs
  do not bump `samples`; unmapped labels teach nothing.
- `test_voices_api.py` — list shape, delete 204/404, auth required,
  names with spaces and unicode round-trip.
- `test_diarization.py` gains: `DiarizeOutput` with `speaker_embeddings`
  → `{label: unit vector}`; a bare `Annotation` (3.x) → no embeddings and
  matching skipped without error.

Client (flutter test):
- `voices_section_test.dart` — list renders rows from the API, Forget
  dialog copy, confirm → DELETE called with the encoded name and the row
  disappears, cancel → nothing, hidden when diarization is off, empty
  state copy.
- `summaries_client_test.dart` — `listVoices` / `forgetVoice` decode and
  encode (space + apostrophe in a name).

Sabotage seams (each quoted in its commit): margin check removed;
overwrite guard removed (stored map clobbered); teaching moved into the
job runner (auto-named recording teaches itself); forget deleting more
than one row; `DELETE /v1/voices/{name}` path built from the name.

## Device proof before tagging

On the Fold, server with the calibrated threshold: (1) a fresh recording
with Jeff alone arrives already reading `Jeff:` with no rename; (2) a
recording with Jeff + a TV voice arrives `Jeff:` / `Speaker 2:`, not two
Jeffs; (3) Settings → Voices → Forget Jeff → next recording arrives
`Speaker 1:` again. Evidence from the server DB and the `voice_match`
log line, not from the phone.

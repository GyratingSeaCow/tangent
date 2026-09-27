# AGENTS.md

This file tells AI coding agents (and humans) how to work on ADH2.

## Project summary

ADH2 is a self-hosted, offline-first voice brain-dump app built for ADHD brains. Flutter client (Android/Linux/Windows) + Python server (FastAPI + Whisper-large-v3). AGPL-3.0.

See [`README.md`](./README.md) for the public-facing overview.

## Working in this repo

### Do

- Read `README.md` and the relevant source before writing any code
- Follow the AGPL-3.0 license header convention (see [`LICENSE`](./LICENSE))
- Use Flutter conventions for the client (`client/`), Python/FastAPI for the server (`server/`)
- Commit small, atomic changes with clear messages
- Update the design spec when reality diverges from the plan

### Don't

- Don't add features not in the v1 spec without updating the spec first
- Don't commit `*.bin`, `*.gguf`, audio recordings, or anything under `data/` — see `.gitignore`
- Don't add cloud-only features without an offline-first equivalent
- Don't break the AGPL by adding closed-source dependencies

## Repo layout (planned)

```
ADH2/
├── client/                # Flutter app (Android, Linux, Windows)
│   ├── lib/
│   ├── android/
│   ├── linux/
│   ├── windows/
│   └── native/            # whisper.cpp bindings, JNI/FFI
├── server/                # FastAPI + Whisper server (Docker)
│   ├── app/
│   ├── tests/
│   ├── Dockerfile
│   └── docker-compose.yml
├── docs/
├── .gitignore
├── LICENSE                # AGPL-3.0
├── README.md
├── CONTRIBUTING.md
└── AGENTS.md              # ← you are here
```

## Status

Shipping — **v1.25.0** (see CHANGELOG.md). Client and server are both
implemented and tested (2345
Flutter tests, 586 server tests, 100 Kotlin tests). The client runs
natively on Linux AND Windows (tray icon, global record hotkey,
close-to-tray, single instance, right-click = long-press; AppImage and
Inno Setup installer under `packaging/`) — verified on CachyOS/KDE
Plasma Wayland and Windows 11; see the README's Desktop sections.

v1.25.0 adds **Google Tasks sync** (two-way, last-write-wins, one Google
list named "Tangent"; folders stay Tangent-only). It runs server-side:
Settings → Google Tasks takes an OAuth client id/secret (Desktop app
type) once, *Connect Google* opens the consent page in the browser and
the server's loopback callback stores the tokens (`google_tasks_link`,
single row, never on a device). A five-minute worker pushes todos whose
`updated_at` passed `google_updated`, pulls with `updatedMin` +
`showDeleted`, applies Google-newer only, and records server-authored
changes in `change_log` so devices pull them like any other edit.
`todos.google_task_id` / `google_updated` are server-only columns —
projected OUT of the sync feed and preserved across device upserts.
Google-origin todos carry `source='google'` and a 'G' chip. Testing-mode
OAuth tokens expire weekly → `reauth_required` + Reconnect banner. See
`docs/design/2026-09-27-google-tasks-sync.md`.

v1.22.0 is client-only: **page backgrounds** and a **vocabulary
cleanup**. `NotebookRuling` gains `graph` (5 mm quad grid) and `dots`
(dot grid at the same 32 px spacing), wire values `graph`/`dots`; the
page style moved out of the insert (+) menu's cycle into a new
top-right editor menu (`notebook-menu`) → *Page background*, a sheet
that previews each of the five styles with the real painter
(`page_background_sheet.dart`). Unknown wire values still fall back to
blank without clobbering the stored value. Separately, every
user-visible "dump" string is now "recording" (identifiers, DB tables,
`/v1/dumps`, and the `Brain Dump` MODE name are unchanged), and
**meeting capture was removed** from the home picker and the list's
create menu — `DumpMode.meeting` survives for existing recordings,
which still render and filter normally. See
`docs/design/2026-09-27-page-backgrounds.md` and
`docs/design/2026-09-27-recordings-rename-meeting-removal.md`.

v1.21.0 adds **ink to text** and pinned playback controls: lasso
handwriting → *Convert to text* posts the lassoed strokes to the new
`POST /v1/ocr/recognize` (TrOCR, same worker as handwriting search) and
swaps the ink for a typed block at the same spot in one undoable step;
the playback panel and Listen-mode waveform are now pinned above the
scrolling transcript. See `docs/design/2026-09-27-ink-to-text.md`.

v1.20.0 adds **transcript → notebook** (client-only): ⋮ → 'Send to
notebook…' on a recording (list, multi-select, detail) picks a notebook
(or creates one) and a shape without opening the editor; the Text shape
now inserts the v1.16-style rendering (`[mm:ss] Name:` per turn, names
from the map, hour promotion, never a faked time) with `stamps` on the
text block (JSON key `stamps`, items {o,l,s,d}; older builds ignore it).
At rest the stamps are tappable spans that seek the same recording's
audio card on the page, or open the detail at that moment; editing the
block reconciles stamps (`reconcileStamps`). One import path
(`importDumpsIntoNotebook`) serves both the ⋮ action and the editor's
Import; the shape sheet gained 'Include audio bubble' (default on,
remembered). See `docs/design/2026-09-27-transcript-to-notebook.md`.

v1.19.0 adds **per-recording translation** and **server-driven summary
status**. Translation: faster-whisper's detected `language` and a
`translated` flag are stored on the dump (server-authored, client DB
v22); non-English recordings show an `ES` / `ES → EN` tag and their
re-transcribe dialog offers 'original' vs 'English' (`JobCreate.
translate` → `task="translate"`). No global switch by design. Summary
status: the worker publishes `summary_status` (queued/running/failed/
null) + `summary_error` + 1-based `summary_queue_position`; success
clears all three in the same write as the summary. The client shows
'Queued — 2nd in line', a red 'Summary failed: <reason>' line with
Retry (no picker) and a local-only dismiss, and a red list pill; the
v1.18.0 local heuristic remains only as the bridge before the server's
first publish. See `docs/design/2026-09-27-translation-and-summary-status.md`.

v1.18.0 adds a visible **summary-in-progress state** (client-only):
`dumps.summary_requested_at` (client DB v21, LOCAL-ONLY — never in the
push payload, never read from a pull) is stamped by
`recordRequestedSummaryTemplate` on the summarize 202 and cleared by
`applyRemoteDump` in the same write that lands a `summarized_at` >= it.
`services/summary_pending.dart` holds the one rule (`summaryPending`:
requested newer than summarized_at AND under 10 min old — the give-up
for offline/failed jobs) plus a swappable clock for widget tests. Detail
shows an indeterminate progress card (template name + 1 s elapsed
ticker) ABOVE the preserved old summary and disables the button as
'Summarizing…'; the list shows a 'Summarizing…' pill and hides ⋮
Summarize again. All driven by the row stream, no polling.

v1.17.0 adds the **speaker name map** (supersedes 1.15.0's rewrite-in-
place): names live in `dumps.speaker_names` (JSON `{"Speaker 1":
"Jeff"}`, client DB v20, device-authored sync field with the absent-vs-
null sentinel); transcript text keeps raw `## Speaker N`. Every surface
renders by look-up — detail read/Edit (unrendered on save), Listen
headers, search snippets, Markdown export (map first, heading pairing
only as fallback) and the server summarizer (substitutes before
`infer`). Re-transcribe keeps names. A one-time client back-fill turns
1.15.0-renamed headings into the map and restores raw labels, refusing
ambiguous pairings. See `docs/design/2026-09-26-speaker-name-map.md`.

v1.16.0 adds **timestamped Markdown export** (client-only): one renderer
(`transcriptMarkdown`) emits frontmatter (title, speakers, template,
timestamps) + `## Summary` + `## Transcript` with one `[mm:ss] Name:`
line per timing segment (`h:mm:ss` for the whole document once any
segment passes an hour); speaker names come from the transcript's
`## ` headings paired to `Speaker N` by first appearance. Obsidian
export gets 'Include timestamps' (default OFF) and 'Include summary'
switches — with both off the vault file is byte-identical to v1.15.0.
⋮ → 'Export Markdown' on list and detail shares (mobile) or writes to
Documents and opens (desktop). See
`docs/design/2026-09-26-timestamped-markdown-export.md`.

v1.15.0 adds **speaker naming** (client-only): ⋮ → "Name speakers" on
list and detail, and tapping a speaker header in Listen mode, opens a
sheet that rewrites `## Speaker N` headings (and `Speaker N:` turn
prefixes) IN PLACE in the transcript text — no name map, no schema.
Listen mode keeps the raw timings labels; a re-transcribe resets names
(the overwrite dialog says so). Suggestion chips come from headings
used on other recordings. See `docs/design/2026-09-26-speaker-naming.md`.

v1.14.0 adds **custom vocabulary**: one global boost-word list
(`app_settings['custom_vocabulary']`, `GET/PUT
/v1/transcription/vocabulary`) fed to faster-whisper `hotwords` on
every window, resolved at job RUN time, and appended as a preferred-
spellings suffix to every summary prompt when non-empty. Settings gets
a 'Custom vocabulary' editor with a live term/token count and a
223-token budget warning. No client DB change. See
`docs/design/2026-09-26-custom-vocabulary.md`.

v1.13.0 adds **transcript search depth** (snippets + match counts on
search results, open-at-match with a prev/next match bar, highlights in
Edit and Listen mode, play from a match when word timings exist) and
**summary templates** (server-owned presets Meeting / Brain dump /
Lecture / Actions only + one Custom slot with a Settings editor;
"Summarize again" picker on detail and list; per-dump `summary_template`
synced with the absent-vs-null sentinel, client DB v19). See
`docs/design/2026-09-26-search-and-summary-templates.md`.

v1.12.0 adds **tap-to-hear**: transcripts get an Edit | Listen toggle;
Listen renders tappable words with karaoke highlighting, confidence
tinting, and a server-computed waveform scrubber. Word timestamps and
peaks ride a server-owned `transcript_timings` dump field (client DB
v18, absent-vs-null sentinel like the summary columns). Server-authored
sync changes now bypass the newer-wins gate — the recording device's own
completion timestamp used to shadow them. See
`docs/design/2026-09-25-tap-to-hear.md`.

v1.11.0 adds the **Windows desktop app** at full Linux parity: WAV
capture (Media Foundation has no Opus encoder), media_kit playback,
loopback-TCP single instance, Shell_NotifyIcon tray, Ctrl+Alt+R global
record hotkey, per-user `tangent-setup-x64.exe`. Find-my-server now
ranks interfaces (Tailscale/WSL adapters no longer hijack the sweep)
and probes the device's own address (self-hosted servers). See
`docs/design/2026-09-25-windows-desktop-parity.md`.

v1.10.0 adds a **Whisper model picker**: Settings lists all five sizes in
accuracy order with Installed badges, installs on demand with a download
prompt and progress, and the server swaps the active model without a
restart. Accuracy is identical either way — the GPU only changes speed.
See `docs/design/2026-09-25-whisper-model-selection.md`.

v1.9.0 adds **AI meeting summaries**: a local llama.cpp model (Qwen 3 4B
Instruct 2507) on the server summarizes meeting transcripts — decisions,
action items, open questions — and the summary syncs to every device and
can be imported into notebooks. Off by default behind an install wizard,
mirroring handwriting search. See `docs/design/2026-09-24-ai-summaries.md`
and `docs/design/2026-09-24-summary-notebook-import.md`.

v1.7.0 adds **handwriting search**: server-side OCR indexes notebook ink,
the word index syncs down to every device, and search itself runs locally
and offline everywhere (including Linux desktop, which has no on-device
recognizer — that is precisely why recognition is server-side). The feature
is off by default behind an install wizard. See
`docs/design/2026-09-21-handwriting-search-ocr.md` for the approved spec.

Open work candidates live in `docs/next-iteration.md`.

---

*This file is for AI agents and humans alike. Update it when conventions change.*
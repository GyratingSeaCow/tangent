# Changelog

All notable changes to Tangent.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.1] - 2026-09-20

### Changed
- **One unified notebook toolbar** — draw toggle, eraser, nib, lasso,
  undo, redo and the pen-size slider share a single always-visible row
  under the title; the second drop-down row is gone. Outside draw mode
  the tools are disabled (grayed), never hidden, so the row never
  reshuffles and a stray tap can't erase or lasso.

### Fixed
- **Eraser performance on full pages** — erasing (and repainting while
  writing) slowed down as a page filled. Stroke hit-testing now rejects
  distant ink with a cached bounding-box check, and a fountain stroke
  renders as one native draw call instead of one per segment. Same
  pixels, verified at the paint level.

## [1.5.0] - 2026-09-20

### Added
- **Folders for dumps** — the Dumps list groups into the same folders as
  notebooks: collapsible headers with counts, unfiled items under
  "No folder". It is one folder system: file a dump into "Work" and it is
  the same "Work" your notebooks use; deleting a folder from either screen
  safely unfiles contents from both. Search results stay flat.
- **Folder rename and delete** — long-press a folder header (in either
  list) for rename/delete. Deleting a folder never deletes its contents;
  they move to "No folder" and the change syncs to other devices.
- **Export to PDF** — the ⋮ menu on any notebook renders it to a PDF
  (ink drawn by the editor's own painter, so pen styles export
  pixel-true; text and checkbox blocks at their positions; page sized to
  the content) and hands it to the system share sheet.
- **Import as audio bubble or text** — confirming the dump picker in a
  notebook now asks how the batch should land: as the draggable playable
  card, or as the transcript in an ordinary editable text block (with an
  honest "(no transcript)" placeholder when there is none).

### Changed
- **Unified list gestures** — long-press on a notebook (row or cover)
  enters the same multi-select mode dumps have (select-all, bulk delete);
  the ⋮ button carries the per-item menu (open, rename, move to folder,
  export, delete).
- **Content-aware insert** — items imported into a notebook land below
  the lowest existing content (blocks and ink), stacking downward,
  instead of cascading from the page top over what is already there.

## [1.4.0] - 2026-09-20

### Added
- **Server discovery** — "Find my server" on the connect screen sweeps the
  local /24 for Tangent servers (unauthenticated `/v1/server/info/public`
  beacon: name, version, auth flag — nothing private) and lists finds live.
- **Pairing** — a device earns its own bearer token by typing a 6-digit code
  read off the server's log (`pairing.code_issued`). Codes live 120 seconds,
  are stored hashed, and die after 5 wrong attempts; each device's token is
  individually revocable via `DELETE /v1/devices/{id}/token`. Manual
  URL + token entry remains for VPN/Tailscale setups the sweep can't see.
- **Multi-step undo/redo** in notebooks — history stacks 100 actions deep
  (strokes, erase sweeps, lasso moves, lasso deletes); redo walks forward
  step by step and any new mutation clears it.
- **Smart lasso** — circle-select ink, text blocks and recording cards
  together (anything >40% inside the loop is caught); drag the selection
  anywhere or delete it as one, with undo. Works with pen and finger.
- **Fountain pen and italic nib** pen styles — pressure-tapered rendering
  with per-style stroke character; raw pressure is stored per point and
  curves apply at render time, so old notebooks gain the styles too.
- **Save-on-back everywhere** — backing out of a notebook or a text note
  saves it; the discard-confirmation dialogs are gone. A failed save keeps
  the screen open with the error visible instead of silently losing work.

### Changed
- Notebook toolbar restructured: the top row is stable (draw toggle, undo,
  redo, save); eraser, nib, lasso and delete live in a second row shown only
  in draw mode.
- Palm rejection no longer suppresses finger input while the lasso is
  active (a selection gesture can't scribble).
- `require_auth` accepts device-bound tokens minted by pairing alongside
  the primary setup token.

### Fixed
- A cancelled gesture (system edge-swipe, palm, second finger) could
  permanently wedge the lasso; pointer-cancel now releases every mode's
  claim and rolls back half-finished selection drags.
- The DEBUG banner no longer shows on debug builds.
- Wrong pairing-code attempts are counted even though the request returns
  401 (the counter previously rolled back with the error response).

## [1.3.0] - 2026-09-19

### Added
- **Notebooks** — endless vertical scrolling page mixing handwriting, typed
  text, checkboxes and embedded recordings. Blocks and imported cards are
  draggable; tapping a recording card opens it for playback.
- **Notebook folders** — file notebooks into folders; folder sections render
  in both the named list and the cover-grid view.
- **Collapsible folder sections** — tap a folder's name in the Notebooks list
  to fold the section down to its header (rotating chevron affordance); tap
  again to expand. State is shared across the list and cover views.
- **Cover-grid view for notebooks** — Samsung-Notes-style book covers as an
  alternate view, persisted across restarts.
- **Audio download (single + bulk)** — pull a synced recording's audio from
  the server back onto the device. Per-row "Download audio" menu entry and a
  bulk "download all audio" toolbar action; downloads land in
  `Tangent Synced Audio/` with playable bindings (publish → attach → bind).
- **Bulk transcribe** from the selection toolbar.
- **Action-agnostic multi-select** in the Dumps list.
- **Stroke eraser** on the pen toolbar, erasing for the whole gesture.
- **Import audio** — bring an existing audio file into Tangent from the home
  screen. The file is copied (never moved) through the same reserve → stage →
  publish path a live recording uses.
- **Text notes** — typed entries alongside voice dumps, with their own durable
  `Tangent Text Notes/` directory.
- **Bluetooth/external microphone selection** for capture.
- Optional **speaker diarization** on the server (pyannote, off by default).
- Segment timestamps in server job results.

### Changed
- **Transcription now runs on your own server, not on-device.** The Android
  whisper.cpp path was replaced by the self-hosted FastAPI + faster-whisper
  server. Recording, playback, notebooks and search remain fully offline.
- Recordings stay on the device by default; syncing to a server is an explicit
  choice, no longer conflated with transcription.
- **Dumps filters collapsed into one dropdown bar** — two stacked chip rows
  became a single row of two dropdowns (`Mode · All ▾` / `Transcript · All ▾`);
  the closed anchor always names the active selection.

### Fixed
- **Stop latency ~10.4 s → ~1.8 s** (T8). The receipt proof was enumerating and
  parsing the entire recordings folder after every capture; it now reads the one
  entry it just wrote.
- **Download with no usable storage folder now says so** ("Choose a storage
  folder first") instead of silently doing nothing — an enabled control that
  did nothing was indistinguishable from a broken app.
- Downloaded synced audio actually plays: the path resolver (Kotlin and Dart)
  both learned the `Tangent Synced Audio/` folder.
- "Select all" selected only a couple of rows; selection is now
  action-agnostic.
- Notebook cards could not be dragged slowly — the page scroll won the gesture
  arena before the card's threshold was reached. The page now yields on touch.
- Card taps, per-block delete, and backspace-deletes-empty-line in notebooks.
- Durable notebook files are re-adopted at startup and republished on save.
- Several SAF publication defects around MIME-coherent names and text notes.
- Transcription status repaired on recordings that synced before the fix.

### Known issues
- Recordings fenced by earlier interrupted runs fail bulk download with
  `Recording identity is fenced`; the fence is never released. Under
  investigation.
- A failed audio fetch (e.g. server unreachable) is not yet surfaced in the
  UI; the download simply does not happen.

## [1.0.0] - 2026-09-13

### Added — Server
- FastAPI server with SQLite (WAL mode) + faster-whisper transcription
- Token-based auth (SHA-256 hashed, single-user per install)
- First-run setup flow that prints a setup URL and returns an API token
- Dump CRUD endpoints (`POST/GET/PATCH/DELETE /v1/dumps`)
- Audio upload endpoint (`POST /v1/dumps/{id}/audio` — multipart, idempotent overwrite)
- Audio download endpoint (`GET /v1/dumps/{id}/audio`)
- Transcription job queue with explicit commits to fix BackgroundTasks race
- Server-Sent Events (`GET /v1/jobs/{id}/stream`) for real-time job progress
- Secretary mode post-processing: extracts action items from meeting transcripts
- Model management (`GET /v1/models`, `POST /v1/models/{name}/pull`)
- Server info endpoint with storage stats (`GET /v1/server/info`)
- structlog logging throughout
- Health check endpoint via `GET /v1/server/info`
- Dockerfile + docker-compose.yml for production deploy

### Added — Client (Flutter)
- On-device Android Whisper large-v3 transcription with checksum-pinned model storage
- In-app recording player with play/pause, elapsed/total time, and draggable seek bar
- Persistent local-transcription progress panel with stages, elapsed time, determinate progress, and cancellation
- Live Dumps-list indicator identifying the clip and stage currently being transcribed
- Loaded-model reuse for sequential notes with idle native-memory cleanup
- Voice recording (opus, 16kHz mono, ~32 kbps) via `record` package
- Big red record button on home screen with live timer
- **Brain Dump mode** (default) — verbatim transcription
- **Meeting mode** — secretary-formatted summary
- Deterministic offline Meeting notes derived only from the local transcript, with separate raw-transcript storage and no meeting upload
- Local SQLite with FTS5 full-text search across dumps
- Local-first storage (always saves before syncing)
- Sync engine: batches pending dumps to server, retry + failure tracking
- Dumps list screen with reactive updates and search
- Persistent All / Brain Dump / Meeting / Awaiting list filters that compose with search
- Dump detail screen: edit title, view transcript, delete, re-transcribe
- Server connection screen: URL + token entry with "Test & Connect"
- Settings screen: trigger mode (tap vs hold), Wi-Fi-only sync, server reconfig
- API token stored in Android Keystore via `flutter_secure_storage`
- SSE client with polling fallback when SSE unavailable
- Connectivity-aware sync (skips when offline or Wi-Fi-only on cellular)
- Path: Android (verified build), Linux, Windows (deps installed)

### Tests
- 57 server tests (pytest) — unit + integration
- 56 client tests (flutter test) — unit + widget
- 1 live SSE integration test (skipped without `TANGENT_LIVE_URL`)
- 114 total tests, all passing

### Documentation
- README rewritten — actual install + run instructions
- AGENTS.md + CONTRIBUTING.md for contributors

### Fixed
- BackgroundTasks race where enqueued jobs were silently dropped (added explicit `db.commit()` in `enqueue_job`)
- SQLite threading issue with async endpoints (added `check_same_thread=False`)
- Broken Dockerfile CMD (changed from `python -m app` to uvicorn factory)

## [0.1.0] - 2026-09-08

### Added
- Initial brainstorming + design spec
- Phase 1 server (FastAPI + SQLite + faster-whisper) — 46 tests
- AGPL-3.0 license
- Docker Compose config

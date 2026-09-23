# Changelog

All notable changes to Tangent.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.2] - 2026-09-23

Patch release: three user-visible fixes found on real devices, plus a
meeting-notes format overhaul.

### Fixed
- **Fountain-pen strokes appeared to erase the ink underneath them.** The
  batched italic-nib renderer emitted segment quads whose winding direction
  flipped at every cursive loop or reversal; under the nonzero fill rule two
  overlapping opposite-winding quads cancelled to a transparent hole exactly
  where letters self-cross. No ink was ever lost — the strokes were intact
  on disk and reappear whole after updating. Quads are now normalized to a
  single winding direction so overlaps can never cancel. PDF export used the
  same painter and is fixed by the same change.
- **Meeting recordings lost their speaker labels.** Speaker diarization
  crashed with a short-final-chunk error on any recording whose length was
  not a clean multiple of its processing window (i.e. most recordings), and
  the transcript silently degraded to unattributed paragraphs. The audio is
  now decoded once and handed to the diarizer as a waveform — the same
  16 kHz mono stream the transcriber hears, which is also the diarization
  models' native rate — so the chunked-decode failure cannot occur.
- **Transcription failed on GPU-enabled servers.** With the GPU compose
  override active, the Whisper backend auto-selected CUDA, but the container
  ships CUDA 13 wheels while the inference runtime links the CUDA 12
  libraries — every transcription failed at first inference (model load
  succeeds; the libraries load lazily). The server now probes for the exact
  runtime libraries before choosing a device and falls back to CPU when they
  are absent. `TANGENT_WHISPER_DEVICE=cpu|cuda` overrides the probe.
- **Release builds could crash at startup after the notification plugin's
  code was shrunk.** R8 stripped generic-type metadata the notifications
  plugin needs; the resulting exception during early init killed sync and
  presented as "can't connect to the server." Keep rules now preserve the
  metadata, and a notification-plugin failure can no longer break startup or
  sync — it degrades to no-notifications with a logged warning.

### Changed
- **Meeting transcripts are now grouped by speaker, not by time.** Instead
  of timestamped paragraphs interleaved in chronological order, the
  transcript renders one section per speaker (numbered by order of first
  appearance) containing everything that speaker said. Text the diarizer
  could not attribute lands in a final `[unattributed]` section. Recordings
  where diarization found no speakers keep the timestamped layout. Server
  and on-device transcription produce byte-identical output. Existing
  meeting notes keep their old text until re-transcribed.
- Settings gained a Licenses page (Tangent's AGPL-3.0 text plus every
  bundled package license), and the Settings footer now reads its version
  from the build instead of a hard-coded string.

## [1.7.1] - 2026-09-22

Patch release: two fixes found running v1.7.0 on real devices.

### Fixed
- **Handwriting search showed "No matches" forever on devices that upgraded
  from an older version.** A device that had been syncing before v1.7.0 had
  its sync checkpoint already past the search index entries, so the index
  never arrived — search looked enabled but always came up empty (a fresh
  install was fine, which is why it slipped through). The server can now
  re-announce the index (`POST /v1/ocr/index/backfill`), and the app asks
  it to automatically when you enable handwriting search on an
  already-provisioned server. Existing devices heal themselves the next
  time the toggle is turned on.
- **Unpaired desktop pointed at an Android-emulator-only address.** A
  Linux/Windows desktop that had never paired defaulted every request to
  `10.0.2.2` — an address that only means something inside the Android
  emulator — and silently timed out. The desktop default is now
  `http://localhost:8765` (the documented server port): correct when the
  server runs on the same machine, and an instant, visible
  "connection refused" instead of a silent hang everywhere else.

## [1.7.0] - 2026-09-22

Handwriting search: find your handwritten notes by typing what you wrote.

### Added
- **Handwriting search** — type a word and Tangent finds it in your
  handwritten notebooks. The search icon sits in the toolbar on both the
  Notebooks list and inside a notebook: the list shows which notebooks match
  with a count and a snippet, and opening one jumps straight to the match
  with the word highlighted on your actual ink. Next/prev walks the matches
  and wraps at the end, Ctrl+F style.

  Recognition runs **on the server**, so search works on every device that
  syncs — including Linux desktop, which has no on-device handwriting
  recognizer at all. Your notebooks sync up, the server reads them, and the
  resulting index syncs back down: **searching itself is local and offline**
  on every device.

- **Handwriting search install wizard** (Settings → Handwriting search) —
  off by default. Turning it on downloads the recognition model with a
  progress notification and a completion notification. Both a CPU and an
  RTX (GPU) flavour are supported: **the GPU flavour is not more accurate**,
  it is the same model running faster. Turning the feature off removes the
  model and the index entirely.

- **Optional GPU compose override** — `server/docker-compose.gpu.yml`, layered
  on with `-f docker-compose.yml -f docker-compose.gpu.yml`. The stock compose
  file stays CPU-only so a GPU-less homelab still works unchanged.

### Fixed
- **Handwriting no longer gets cut off on narrow screens** — a notebook page
  was scaled to fit the typed-text column rather than its actual content, so
  on a narrow screen (a foldable's cover display, for example) everything
  written past that column was clipped off the right edge with no way to
  scroll to it. Pages now scale against their real content width: ink,
  imported images, and blocks you have dragged to the right. Pages that fit
  the column render exactly as before.

- **Notifications can no longer take the app down at startup** — in a release
  build the notification plugin could fail to initialise and kill the startup
  sequence with it, leaving the app running but never syncing, which looked
  for all the world like the server was unreachable. Notification failures now
  degrade to "no notifications" and are logged; sync always starts.

- **Server info no longer times out once handwriting search is installed** —
  the storage-usage figure walked the whole data directory including the
  ~9 GB recognition environment, taking over a minute and exceeding the app's
  request timeout. Every device then reported the server as unreachable and
  stopped syncing. The recognition environment is now skipped (it is
  reinstallable machinery, not your data) and the call returns in a fraction
  of a second.

- **Changing servers no longer leaves handwriting search on the old one** —
  the Settings section cached the server address at first load, so after
  pointing the app at a different server the handwriting toggle silently kept
  talking to the previous one until the app was restarted.

- **Returning to Settings mid-install shows live progress** — leaving the
  Settings screen while the model downloaded and coming back showed an error
  instead of the running install.

### Known behaviour
- If an install finishes while you are away from the Settings screen, the
  toggle rests OFF until one tap flips it on. This is deliberate: a device
  that installs the model must not silently enable the feature on your other
  devices.

## [1.6.1] - 2026-09-21

Quality-of-life release: the notebook tools now behave the way they look.

### Added
- **Pairing codes in Settings** — "Pair a new device" on any paired device
  shows pending 6-digit codes big enough to read across the room, with the
  requesting device's name, platform and a live 120-second countdown,
  refreshed every 5 seconds. No more reading codes out of the docker log.
- **Pen hover cursor** — a thin ring follows the S-Pen while it hovers,
  showing exactly where the nib will land and how wide the mark will be:
  pen stroke width, the highlighter's full rendered band, or the eraser's
  reach when erasing (side button included). Stylus only — a mouse never
  shows it — and the lasso pen stays ring-free.

### Fixed
- **Eraser reaches the whole highlighter band** — erase reach followed the
  nominal stroke width, so most of a wide highlighter band was untouchable;
  it now follows the rendered ink per tool. Pen erase reach is unchanged.
- **PDF export renders imported images** — exported pages drew a
  "🖼 Picture" placeholder where images sat; the actual image pixels now
  render at the block's position, with the placeholder kept only as the
  fallback for undecodable image data.
- **Lasso catches wide rows where you see them** — text and checkbox rows
  were lassoed against a nominal 300×90 box regardless of rendered width,
  so circling the right half of a full-width row selected nothing. The
  lasso now measures the real laid-out size (images already used theirs;
  the 40% catch threshold is unchanged).
- **Server setup hint names the server, not the user** — the first-run
  example suggested `"display_name": "Your Name"`, so servers introduced
  themselves by their owner's name; the example is now "Tangent Server"
  with a note that the name is the machine's.

## [1.6.0] - 2026-09-21

Linux desktop companion (verified on CachyOS, KDE Plasma 6 Wayland) and
notebook pen upgrades. The client now runs natively on Linux with the
full notebook/dump feature set, packaged as `Tangent-x86_64.AppImage` —
now built and verified in CI rather than by hand.

### Added
- **Pen colours** — long-press the pen for its palette (white, blue,
  red, amber). The pen keeps its colour for the session and the toolbar
  icon tints itself to match.
- **Highlighter** — a real highlighter beside the pen: a wide,
  translucent chisel band that always paints *beneath* handwriting, so
  ink stays crisp on top. Its own long-press palette (yellow, lime,
  blue, pink) and its own colour memory. Highlights export pixel-true
  to PDF, and notebooks keep their exact on-disk format — files with no
  colours re-encode byte-identical.
- **Insert images into notebooks** — the notebook ⋮ menu places a photo
  or image file on the page as a movable block; lasso, drag and undo
  treat it like any other block. (Linux desktop port included.)
- **Linux desktop support** — the Flutter client builds and runs
  natively on Linux. Storage uses real directories
  (`~/Documents/Tangent/`, no folder-authorization step); playback of
  recorded and synced audio is bridged to libmpv via media_kit
  (just_audio has no Linux backend); recording captures through
  PipeWire (`parecord` + `ffmpeg`) with the same 16 kHz mono Opus
  pipeline as Android.
- **System tray icon** — Tangent lives in the tray (StatusNotifierItem
  spoken directly over D-Bus). Left-click opens the app window;
  right-click offers Open App / Start Recording / Exit. Implemented
  without libappindicator, which hardcodes menu-on-left-click.
- **Close-to-tray** — the window's X button hides to the tray instead
  of quitting (the global hotkey needs a living instance); the tray's
  Exit is the one real quit. Only armed when a tray host exists, so a
  trayless desktop keeps normal close-to-quit.
- **Global record hotkey** — `tangent --record` from a second process
  forwards a toggle to the running instance over a Unix socket in
  `XDG_RUNTIME_DIR` and exits; bind it to a key (e.g. Meta+R via KDE
  custom shortcuts) to start/stop a capture from anywhere on the
  desktop. A plain second launch raises the existing window instead.
- **Right-click = long-press** — every long-press context gesture
  (multi-select on dump/notebook rows and covers, folder header
  rename/delete) also fires on mouse right-click, derived from the same
  handler so the two inputs cannot drift.
- **AppImage packaging** — `packaging/build-appimage.sh` wraps the
  Flutter bundle plus libmpv and its non-baseline dependency closure
  into a self-contained `Tangent-x86_64.AppImage`.

### Fixed
- **Notebook toolbar tools tappable any time** — the draw-mode tools no
  longer require entering draw mode first; tapping eraser, nib or lasso
  from cold activates draw mode with that tool, matching the pen.
- **Wide highlighter marks near the page edge no longer clip in PDF
  export** — content bounds now pad for the highlighter's full band
  width instead of a fixed margin.
- **First words clipped on Linux** — record_linux reports "started"
  when `parecord` spawns, ~120–190 ms before the PipeWire stream is
  live. The recorder now holds "recording" until the mic stream shows
  real amplitude (bounded at 700 ms so a hardware-muted mic can't hang
  the button).
- **PDF export crashed on Linux** — the share sheet path ends in
  share_plus's `shareXFiles`, which is unimplemented on Linux. Desktop
  exports now land in `Documents/Tangent/Exports/` (collision-safe
  names, never overwrites) and open in the system viewer, with the
  path shown either way.
- **Missing Secret Service no longer breaks startup** — without
  KWallet/gnome-keyring, secure-storage reads throw; startup now
  launches unpaired and the connect screen states the problem instead
  of crashing or showing silently empty fields.
- **Linux build with clang ≥ 18** — vendored plugin code
  (flutter_secure_storage's json.hpp, appindicator headers) tripped
  `-Werror` on newer diagnostics; those exact warnings are downgraded,
  guarded by compiler capability checks.

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

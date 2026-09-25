# Next iteration

Work agreed but deliberately not started, so it is not carried in conversation
alone. Each item states what is already true, so the next session does not
re-derive it.

---

## 1. Open items

### 1.0 Name the active Whisper model in the transcription notification

**Status:** requested by Jeff 2026-09-25, right after the model picker
shipped. Now that the model is selectable, the progress UI must say which
one is actually working — "faster-whisper" is the engine, not the choice.

Two places say the wrong thing today:

- `client/lib/services/transcription_notifications.dart:57` — the shade
  notice is `title: 'Transcribing'` / `body: '1 recording'` with no model
  anywhere. Wanted: the active model named, e.g.
  `Transcribing with large-v3` (or body `1 recording · large-v3`).
- `client/lib/screens/dump/dump_detail_screen.dart:1217` — the in-screen
  line reads "The server is decoding audio with faster-whisper." Wanted:
  the model name, e.g. "decoding audio with large-v3 on your server".
  `client/lib/screens/settings/settings_screen.dart:209` describes the
  architecture generally, so "faster-whisper" is still correct THERE.

Implementation notes:

- The active model already arrives from `GET /v1/transcription/models`
  (`active`) and from `/v1/server/info` (`default_model`, made truthful in
  the picker arc). `WhisperModelClient` and the `SettingsStore`
  `whisper_model` offline mirror both exist — read the mirror so the notice
  never blocks on the network, and refresh it whenever the catalogue is
  fetched.
- `buildTranscriptionNotice(...)` is a pure function with a
  `TranscriptionNotificationPort` double in tests — add the model as a
  parameter and pin the copy, including the unknown-model fallback (never
  render "Transcribing with null"; fall back to today's wording).
- Per-job override exists: `JobCreate.model` (server `app/models.py:86`)
  defaults to a hardcoded `"large-v3"` while the engine actually loads the
  server-selected model (proved live: job row said large-v3, engine logged
  `model=small`). The notice must report what the ENGINE will use, not the
  job row's field — and that stale default is itself worth fixing so the
  two cannot disagree.

### 1.1 Linux AppImage: verify handwriting search on desktop (v1.7.0 E2E gate)

**Status:** owed. The v1.7.0 tag's Release workflow builds and attaches
`Tangent-x86_64.AppImage`, so no local Linux build is needed — download it
from the release and run the checks below.

This is E2E checkpoint 6 and it is the WHOLE REASON the feature is
server-side: ML Kit is Android/iOS-only, so the Linux desktop must be able
to search handwriting with no on-device recognizer present. Everything it
depends on is already proven on Android:

- server indexes and serves the rows (248 rows / 10 notebooks / 0 errors);
- `include_ink_index=true` pull works and the client mirror applies it;
- search, highlight and next/prev all verified on the Fold's cover screen.

What to check on the AppImage: the search icon appears on both Notebooks
home and in-notebook, a query returns match counts + snippets, tapping a
result opens at the highlighted match, and next/prev wraps. No install
wizard should be reachable or needed — the desktop never installs an OCR
env, it only consumes the synced index.

Note: the desktop fallback base URL is fixed (`900f726`):
`defaultServerBaseUrl()` returns `http://localhost:8765` on desktop, the
emulator alias only on Android. An unpaired desktop now fails loud
(connection refused) instead of black-holing into `10.0.2.2`. Pairing
before testing is still the right path for checkpoint 6.

### 1.2 Bluetooth mic — DONE (2026-09-23, confirmed by Jeff on device)

Root cause: BLUETOOTH_CONNECT was declared but never runtime-requested, so
Android 12+ refused SCO bring-up silently. Shipped (6b58d64): automatic
call-style routing — BT headset mic when connected, built-in otherwise —
with a runtime Nearby-devices prompt on first record, and an
"Auto-enable Bluetooth audio" toggle (default ON) in Settings explaining
the narrowband quality tradeoff. Manual per-device picking removed.
Verified live on the Fold: flinger patch moved capture from
AUDIO_DEVICE_IN_BUILTIN_MIC to AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET;
Jeff confirmed end-to-end recording works.

### 1.3 Capitalize the app name — DONE (shipped in v1.8.0)

Verified 2026-09-25: `android:label="Tangent"` (AndroidManifest.xml:30) and
the Windows window title `L"Tangent"` (main.cpp:30). Original note kept
below for the Linux `.desktop` check, the one site not re-verified.

Jeff, 2026-09-23: "we need to capitalize the app name … Don't worry about
changing it now. We can catch that in a future release." The Flutter
`MaterialApp` title already says 'Tangent'; the launcher/window names
don't. Audited sites (display strings only):

- `client/android/app/src/main/AndroidManifest.xml:30` —
  `android:label="tangent"` → `"Tangent"` (the home-screen launcher name;
  the most visible one)
- `client/windows/runner/main.cpp:30` — window title `L"tangent"`
- `client/windows/runner/Runner.rc:93-98` — FileDescription /
  InternalName / ProductName `"tangent"` (OriginalFilename stays
  lowercase `tangent.exe`)
- Linux: `.desktop` entry name under `packaging/` if it says lowercase
  (check at fix time; AppImage display name rides on it)

Do NOT touch: `pubspec.yaml name: tangent` (Dart package name, must stay
lowercase), `BINARY_NAME` in both CMakeLists (executable filename),
`APPLICATION_ID`/`applicationId` `dev.tangent.tangent` (changing it
orphans installed apps' data). Display strings only.

### 1.4 Bulk audio import in Settings — DONE (2026-09-23)

Shipped: Settings -> Import -> "Import audio files..." multi-select
picker (EXTRA_ALLOW_MULTIPLE + clipData on the existing cache-copy
handler), sequential runs of the same AudioImportRunner the home
button uses, per-file progress on the tile, failures named in the
summary (one bad file never aborts the rest — sabotage-proven).
Home-screen single-file button unchanged.

### 1.6 GPU transcription restore — DONE (shipped in v1.8.0)

Verified live: whisper runs `device=cuda` on the RTX 5070 (a 71 s recording
transcribes in ~4.5 s vs ~40 s on CPU). Note the SEPARATE Blackwell block
for llama.cpp summaries, which is NOT fixed by this — see 1.8.

Dockerfile now installs nvidia-cublas-cu12 + nvidia-cudnn-cu12 (ctranslate2
links the CUDA-12 runtime; torch's transitive wheels are CUDA-13 and do not
satisfy it). resolve_whisper_device() probes before selecting cuda, so the
wheels are inert on CPU-only hosts. Verification bar: run a REAL inference
in the container and consume the generator — construction succeeding proves
nothing (lazy CUDA load).

### 1.7 Release v1.8.0 — DONE (2026-09-23); v1.9.0 shipped 2026-09-25

Bundle since v1.7.1/1.7.2: notebook home widget (9fe1aca), automatic
Bluetooth mic routing (6b58d64), bulk audio import (9e9d9c3), Obsidian
export (91f8622), REST API docs (46be553), perf/pen fixes. FOLD IN item
1.3 (capitalize display name) per Jeff 2026-09-23: "take care of this in
the next release." CHANGELOG, tag, GitHub release, Licenses tab check,
AGENTS.md test counts, parity install on all three devices (S10 FE returns
after this round of updates).

### 1.8 Blackwell CUDA for AI summaries — BLOCKED on upstream

The summarizer's llama-cpp-python cu124 wheel SIGILLs (exit -4) on the RTX
5070: Blackwell needs sm_120 kernels, which require CUDA 12.8+, and abetlen
ships cu121–cu124 only. The install's CPU-downgrade path is therefore the
shipped runtime on this host (~40 s per summary including model load).
Accuracy is identical — GPU only changes speed — so nothing is lost but
time. The LD_LIBRARY_PATH and symlinked-venv bugs found on the way are
fixed and pinned (`9c2f433`, `7fd02c3`); this is purely a wheel-availability
wait. Revisit when cu128+ wheels exist, or vendor a source build.

Note: whisper transcription is UNAFFECTED and does run on CUDA (item 1.6) —
ctranslate2 vendors its own runtime and has Blackwell support.

### 1.5 Hardware-feedback-gated ideas (no work queued)

Hover-ring linger/thickness tuning if 250 ms feels wrong on device; toolbar
`visualDensity.compact` eyeball. Jeff 2026-09-25 on the hover ring and
toolbar density: "that feels fine" — no change wanted.

Flip-to-erase: **untestable, no hardware.** Jeff has no flip-to-erase pen
(2026-09-25). His expectation when one appears: it should behave like the
side-button press already does — i.e. route through the SAME erase path the
barrel button takes, not a second parallel implementation. Whenever a pen
that emits `PointerDeviceKind.invertedStylus` shows up, wire it to that
existing handler and verify on hardware before shipping.

New arcs come from daily-use annoyances.

## 2. Done (2026-09-21, v1.6.0 → v1.6.1)

- v1.6.0 cut: pen colours + highlighter (6-task SDD arc), notebook image
  import, Linux desktop AppImage via CI, all version sites reconciled.
- Eraser reach follows the rendered highlighter band (`d298386`).
- PDF export renders imported images, corrupt-bytes fallback (`9b5bdf3`).
- Pairing codes in Settings — no more docker-log reading (`117a305`);
  server display_name renamed "Tangent Server" (was "Jeff"), setup hint
  now says to name the machine, not yourself.
- Pen hover cursor, phase 6 (`ebaf43e`): honest-radius ring (pen width /
  highlighter band / eraser reach), stylus-only, cleared on contact,
  lasso-mode exempt (`9f038a2`). Phase 5 (side-button eraser) discovered
  already shipped in `_isErasing`.
- Lasso measures real block footprints via RenderBox (`3020553`); dump
  cards stay on the nominal 300×90 the 40% threshold was tuned against.

## 3. Done (2026-09 arc, earlier)

- Pen input phases 1–4: palm rejection, pressure width, fountain pen
  (`f238d3a`), italic nib + gamma (`2b98407`) — hardware-verified.
- Smart lasso: ink + blocks/recordings, 40% catch threshold, drag/delete/
  undo (`3a06581`, `add5ce4`, `a11ebb1`, `4c8f349`).
- Multi-step undo/redo, 100 deep (`09a9b73`).
- Save-on-back everywhere, replacing discard dialogs (`e13ea6e`).
- DEBUG banner removed (`4c8f349`).
- Multi-device sync discovery/pairing (`4f352bc` server, `e01ad1e` client):
  unauthenticated `/v1/server/info/public` beacon, client /24 sweep ("Find
  my server"), 6-digit log-code pairing minting device-bound revocable
  tokens. E2E-verified against the live container and by Jeff on hardware.
- Pen-writes-without-draw-mode (`dea6b39`), lined page templates
  (`f0916cb`), dumps filter bar (`523bc47`), amplified capture
  (`8b65a6f` + `baa6a7f`) — all verified per 2026-09-19 status sweep.
- Keystore backed up to local NAS (2026-09-19).

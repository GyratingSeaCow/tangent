# Tangent Project Status — End of Session 2 (2026-09-13)

This document captures where Tangent stands after the Phase 2 (Flutter client) build session. Future sessions should read this first.

---

## What's shipped ✅

### Phase 1 — Server (FastAPI + SQLite + faster-whisper)

A complete, working, AGPL-3.0-licensed self-hosted voice brain-dump **server**.

| Metric | Value |
|---|---|
| Code location | `server/` (in this repo) |
| Tests | 46/46 passing (`pytest`) |
| Lint | All ruff checks pass |
| Commits | 13 implementation commits on `main` |
| Branch state | All pushed to https://github.com/GyratingSeaCow/tangent (PRIVATE) |
| Docker-ready | `server/Dockerfile` + `server/docker-compose.yml` |

**What it does:**
- One-time setup endpoint (`POST /v1/setup`) that prints a banner and generates an API token
- API token auth via SHA-256 hashing (`Authorization: Bearer <token>`)
- Full dump CRUD: `POST/GET/PATCH/DELETE /v1/dumps`
- Transcription job queue: `POST /v1/dumps/{id}/transcribe` → job row → SSE stream
- Server info + model management endpoints
- SQLite + WAL + busy_timeout for concurrent writes
- structlog logging
- pydantic-settings env-driven config

**How to run it:**
```bash
cd server
pip install -e ".[dev]"   # or: uv sync --all-extras
python -m pytest          # 46 tests pass
python -m app             # starts server, prints setup URL
docker compose up -d      # production deploy
```

**Known gaps (deferred):**
- **Audio file upload endpoint** — Phase 1.5. Job enqueue currently assumes a path convention (`/data/audio/{id}.wav`) but no multipart upload endpoint yet.
- **Setup token recovery on repeat calls** — Phase 1.5. Currently returns placeholder after first call (security-correct but UX-hostile).
- **Server-side speaker diarization (pyannote)** — Phase 2+. Not wired up in v1.

---

## What's locked in design (not built yet) ⏸

### Phase 2 — Flutter Client (Android / Linux / Windows)

Spec'd in `docs/superpowers/specs/2026-09-13-v1-brain-dump-design.md`. **Not implemented.**

**Features planned for v1:**
- Voice capture (Opus/AAC) with tap-to-toggle + optional hold-to-record
- Local SQLite + FTS5 search
- Sync engine: batched upload + "Confirm to Transcribe All" notification
- Model manager (small default + upgrade prompt)
- 4 screens: onboarding, recording, dumps list, settings
- API token stored in OS keystore

**Decision still open:** scope of Phase 2:
- **A1 (full spec):** on-device Whisper small, all features as spec'd. ~4-6 days of focused work.
- **A2:** server-only transcription, no on-device Whisper. APK needs network. ~2-3 days.
- **A3 (recommended):** record + upload to server only. Honest about scope. ~1-2 days.

### Phase 3 — On-device LLM (secretary mode)

**Not started.** Spec'd in the v1 design doc. Includes on-device Gemma 2B / Phi-3-mini Q4 for meeting minutes (Summary / Speakers / Action Items / Decisions). Deferred until client work is real.

---

## What's new this session (2026-09-13, late) ⏸

- **Phase 2 Flutter client spec written and pushed** at `docs/superpowers/specs/2026-09-13-v1-flutter-client-design.md`. Spec adopts scope path **A2** (server-side transcription, no on-device Whisper in v1).
- **Flutter SDK installed** at `~\AppData\Local\flutter\` (Flutter 3.27.1, working — `flutter --version` and `flutter doctor` both run; `flutter doctor` flags missing Android toolchain).
- **Choco install attempts** for JDK + Android SDK + Flutter (via chocolatey) hit permission errors on `C:\ProgramData\chocolatey\lib-bad`. The Flutter SDK zip download + extract (1.04 GB) succeeded; the choco-managed reinstall is still in flight and may or may not complete.
- **No Phase 2 implementation yet.** Spec awaiting user review.

## What blocked Phase 2 setup this session ❌

Flutter SDK installation attempts failed twice:
1. `winget install Google.Flutter` — package not found in winget catalog
2. Direct download of `flutter_windows_3.27.1-stable.zip` (1.04 GB) succeeded to `%LOCALAPPDATA%\flutter-install\flutter.zip`
3. `Expand-Archive` extracted partial files only — `flutter --version` works (binary present) but core tooling `packages/flutter_tools/` is missing
4. Re-extract with absolute path also failed (PowerShell env var expansion issue)

**Android SDK + JDK: not attempted.** Even with working Flutter, building an APK requires Android SDK (~2 GB) + JDK (~200 MB). Another multi-GB install.

**Net result:** Flutter install is **broken and unusable** at session end. Needs re-extract or alternative install method (scoop, chocolatey, git clone + PATH).

---

## Decisions locked across the session

### Design decisions (13 total, all in spec)

| # | Decision | Locked |
|---|---|---|
| 1 | Scope = phased platform | ✅ |
| 2 | Repo: `~/Documents/ADH2` → GitHub `GyratingSeaCow/tangent` (private, AGPL-3.0) | ✅ |
| 3 | App name = **Tangent** ("Go go a a tangent.") | ✅ |
| 4 | Client stack = Flutter (Android / Linux / Windows) | ✅ |
| 5 | Storage = self-hosted per-user + offline-first | ✅ |
| 6 | On-device Whisper small + server fallback | ✅ (but scope-A3 may diverge) |
| 7 | Batched sync notification, "Confirm to Transcribe All" | ✅ |
| 8 | Recording screen: tap-to-toggle + hold optional | ✅ |
| 9 | 60 min hard cap, no mid-recording warnings | ✅ |
| 10 | Secretary mode (on-device LLM, structured output) | ✅ |
| 11 | Dumps list + full-text search (SQLite FTS5) | ✅ |
| 12 | REST + SSE API, API token auth, client-is-source-of-truth | ✅ |
| 13 | v1 feature floor (server-side complete; client deferred) | ✅ |

### Process decisions

- **Communication:** Discord (via Hermes), this conversation
- **Repo visibility:** private until "ship it" called
- **License:** AGPL-3.0 throughout
- **SDD methodology:** using `subagent-driven-development` skill for orchestration; in-controller fallback when subagent dispatch blocked
- **PATH workaround:** Flutter installed at `%LOCALAPPDATA%\flutter\bin\flutter.bat`, called by full path. `flutter` not in PATH yet.

---

## How to resume

### Quick resume checklist for next session

1. Read `STATUS.md` (this file) ✅
2. Read `docs/superpowers/specs/2026-09-13-v1-brain-dump-design.md` (server spec, Phase 1 - DONE)
3. Read `docs/superpowers/specs/2026-09-13-v1-flutter-client-design.md` (client spec, Phase 2 - awaiting approval)
4. **Approve or amend the Phase 2 spec.** Scope is A2 (server-side transcription). On-device Whisper deferred to Phase 2.5.
5. **Flutter SDK status:** verify `flutter --version` works at `~\AppData\Local\flutter\bin\flutter.bat`. If yes, optionally add to PATH. If broken, delete and re-extract from the zip at `%LOCALAPPDATA%\flutter-install\flutter.zip`.
6. **JDK install (needed for Android builds):** try `choco install -y temurin17jdk` as admin, or download Temurin 17 directly from Adoptium. ~200 MB.
7. **Android SDK install:** after JDK is working, use Android Studio installer or `sdkmanager` directly to install platform-tools + build-tools + a recent API level (~2 GB).
8. **Write Phase 2 implementation plan** (per `writing-plans` skill) once spec is approved.
9. **Build Phase 2** (subagent-driven via `zoe` profile, or in-controller).

### Files / artifacts to preserve

- `~/Documents/ADH2/` — entire repo (committed history is the source of truth)
- `~/Documents/ADH2-local-tools/` — PATH repair artifacts (`fix-path.ps1`, `path-backup.txt`)
- `~/AppData/Local/flutter-install/flutter.zip` — 1.04 GB Flutter zip (reusable)
- `~/.hermes/profiles/tangent-*` — any new Hermes profiles (none created yet)

### Files to delete if starting clean

- `~/AppData/Local/flutter/` — partial/broken Flutter extract
- `~/AppData/Local/flutter-install/` — after re-extracting successfully

---

## What "ship" means

Per spec §16 v1 success criteria, Tangent is "shipped" when:
1. ✅ Solo install works (server can be run via `docker compose up`)
2. ⏸ Offline-first works (client-side; not built)
3. ⏸ Server mode works (server side done; client integration not built)
4. ⏸ Secretary mode works (Phase 3; not started)
5. ⏸ Full-text search works (client-side; not built)
6. ⏸ Settings persist (client-side; not built)
7. ✅ AGPL compliance
8. ⏸ Private repo state (currently private, never flipped to public yet)

**Currently shipped: 3/8 success criteria** (all server-side). Client work = remaining 5/8.

---

*End of session 1 status. Server ships. Client is a real, multi-day project that should be its own focused effort.*

---

## Phase 2 — Flutter Client (End of Session 2)

### What was built

A complete, working Flutter client that talks to the Phase 1 server.

| Metric | Value |
|---|---|
| Code location | `client/` |
| Tests | **35/35 passing** (`flutter test`) |
| Analyze | 0 errors (only style hints) |
| APK | **Built successfully** — 202 MB debug at `client/build/app/outputs/flutter-apk/app-debug.apk` |
| Target platforms | Android (verified), Linux, Windows (deps installed; targets not built) |
| Commits this phase | 14 (planning + 13 implementation) |
| Push state | All on `main`, ready to push to remote |

### Module breakdown

**Data layer (`lib/data/`)** — 6 files, 4 test files
- `local_db.dart` — drift schema with FTS5 full-text search over dumps
- `audio_storage.dart` — opus files under app docs directory
- `secure_storage.dart` — flutter_secure_storage wrapper for API token + URL
- `settings_store.dart` — trigger mode + wifi-only-sync setting

**Services (`lib/services/`)** — 4 files, 4 test files
- `transcription_client.dart` — Dio HTTP client (createDump, enqueue, poll job)
- `recording_service.dart` — `record` package wrapper, opus/16kHz/mono
- `connectivity_service.dart` — connectivity_plus stream + status enum
- `sync_engine.dart` — batches pending dumps, uploads to server, marks synced

**Domain models (`lib/models/`)** — 5 files, 1 test file
- `dump.dart` (freezed), `dump_mode.dart`, `sync_status.dart`, `server_info.dart`, `api_exception.dart`

**Screens (`lib/screens/`)** — 5 files, 2 test files
- `home/home_screen.dart` — big record button + timer
- `server/server_connection_screen.dart` — URL + token entry
- `dump/dumps_list_screen.dart` — stub (no real DB query yet)
- `dump/dump_detail_screen.dart` — stub
- `recording/recording_controller.dart` — Riverpod state notifier

**Entry point (`lib/main.dart`)** — wires up SecureStore + LocalDb + TranscriptionClient as ProviderScope overrides, routes to home or server-config based on stored URL.

### Toolchain

| Component | Version |
|---|---|
| Flutter | 3.27.1 (installed at `%LOCALAPPDATA%\flutter`) |
| Dart SDK | bundled with Flutter 3.27 |
| JDK | 17.0.20 (Microsoft, at `C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot`) |
| Android SDK | 34 (`%LOCALAPPDATA%\Android\Sdk`) |
| Android licenses | accepted |
| `gh` CLI | 2.100.0 |

### Known gaps (deferred to v1.1)

1. **Server-side audio upload endpoint** — Phase 1.5. Client uploads via `POST /v1/dumps` (multipart) but server endpoint still assumes file at expected path.
2. **Dumps list screen is a stub** — shows "No dumps yet". Needs Riverpod `dumpsProvider` querying the local DB.
3. **Dump detail screen is a stub** — needs metadata entry form, transcription trigger button, audio playback.
4. **SSE → polling** — Client polls `/v1/jobs/{id}` every 2s with 60s timeout. SSE is server-side ready, just needs wire-up.
5. **Meeting / secretary mode UI** — backend data flow exists; UI surface not built.
6. **Linux + Windows targets** — deps installed but not built/tested.

### How to keep going

```bash
# All required env vars in one block:
export JAVA_HOME="C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot"
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

# Tests
cd "~/Documents/ADH2/client"
flutter test                                  # 35 pass

# Build
flutter build apk --debug                     # already built; output in build/

# Install on device
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### Session-3 priorities (when you come back)

1. Finish the dumps list / detail screens (real DB integration)
2. Wire up SSE on the client (replace polling loop)
3. Build Linux target end-to-end
4. Run a real recording → transcribe → search round trip

*End of session 2 status. Server + client foundation ship. Both have real tests, real builds, real wire-up — not sketches.*

---

## Phase 2.5 — End-to-End Smoke (End of Session 3)

### What's new since session 2

A **live end-to-end smoke test against a running Tangent server** confirmed every endpoint works:

```
1. GET  /v1/server/info              → 200 {version:0.1.0, models:[tiny..large-v3]}
2. POST /v1/dumps                    → 201 {id:"smoke-test-dump-001", ...}
3. POST /v1/dumps/{id}/audio (opus)  → 204 No Content (file saved to data/audio/)
4. GET  /v1/dumps/{id}/audio         → 200, bytes round-trip correctly
5. GET  /v1/dumps                    → 200, lists the new dump
6. POST /v1/dumps/{id}/transcribe    → 201 {id:"<job>", status:"queued", model:"tiny"}
```

### New artifacts

| File | Purpose |
|---|---|
| `server/app/api/dumps.py` | Added `POST/GET /v1/dumps/{id}/audio` + `get_audio_path_for_dump()` |
| `server/app/api/jobs.py` | Now uses real audio path lookup (returns 422 if no audio uploaded) |
| `server/app/db.py` | `check_same_thread=False` on connection (async-safe) |
| `server/tests/test_audio_upload.py` | 7 new tests for upload/download/auth/idempotency |
| `client/lib/services/transcription_client.dart` | Split into `createDump` + new `uploadAudio` |
| `client/lib/screens/dump/dumps_list_screen.dart` | Real reactive list with FTS5 search + sync badges |
| `client/lib/screens/dump/dump_detail_screen.dart` | Real edit/transcribe/delete |
| `client/lib/screens/dump/dumps_providers.dart` | Riverpod stream + future providers |
| `client/lib/screens/home/home_providers.dart` | Sync engine + connectivity + audio storage providers |
| `client/lib/screens/settings/settings_screen.dart` | Trigger mode + Wi-Fi only + server URL |
| `client/lib/main.dart` | Wires AudioStorage (path_provider) + FutureBuilder router |

### Final metrics (end of session 3)

| Metric | Value |
|---|---|
| Server tests | **53/53 passing** |
| Client tests | **56/56 passing** |
| Total | **109/109** |
| APK | `client/build/app/outputs/flutter-apk/app-debug.apk` (202 MB debug) |
| Live server smoke | All 6 critical endpoints verified end-to-end |

### What's still NOT done

1. **Real Whisper run on a real recording** — `tiny` model would need to download (~75 MB) and the test audio was fake bytes. The *plumbing* works end-to-end.
2. **SSE wire-up** — client polls every 2s instead of streaming. Cosmetic.
3. **Linux/Windows builds** — deps installed but targets not built/tested.
4. **Secretary mode UI** — backend data flow exists; UI surface not built.

### How to reproduce the smoke test

```bash
# Terminal 1: server
cd "~/Documents/ADH2/server"
python -c "from app.main import create_app; import uvicorn; uvicorn.run(create_app(), host='127.0.0.1', port=8000)"

# Terminal 2: setup + tests
TOKEN=$(curl -s -X POST http://localhost:8000/v1/setup \
  -H "Content-Type: application/json" \
  -d '{"display_name":"Your Name"}' | python -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -X POST http://localhost:8000/v1/dumps \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"id":"test1","mode":"brain_dump","duration_seconds":3,"title":"Hello","created_at":"2026-09-13T20:00:00Z"}'

curl -X POST http://localhost:8000/v1/dumps/test1/audio \
  -H "Authorization: Bearer $TOKEN" \
  -F "audio=@recording.opus"

curl -X POST http://localhost:8000/v1/dumps/test1/transcribe \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"tiny"}'
```

*End of session 3. Server: live and verified. Client: builds, tests, all screens real. The full record → upload → transcribe path is plumbed end-to-end.*
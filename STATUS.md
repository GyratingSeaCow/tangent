# Tangent Project Status — End of Session 1 (2026-09-13)

This document captures where Tangent stands at the end of the initial brainstorming + Phase 1 build session. Future sessions should read this first.

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
2. Read `docs/superpowers/specs/2026-09-13-v1-brain-dump-design.md` (approved spec)
3. Read `docs/superpowers/plans/2026-09-13-v1-brain-dump.md` (Phase 1 plan — DONE)
4. **Phase 2 path decision needed.** Pick A1 / A2 / A3 (see "What's locked" above). My recommendation is A3.
5. **Flutter SDK fix needed.** Options:
   - Re-extract `flutter.zip` with a different tool (tar, 7-zip, or git clone of flutter/flutter repo)
   - Use `scoop install flutter` (if scoop is installed)
   - Use `choco install flutter` (if chocolatey is installed — it is)
   - Re-download the zip and retry extraction
6. **Android SDK + JDK install** (only if A1 or A2 chosen)
7. **Brainstorming session for Phase 2** (per `brainstorming` skill)
8. **Write Phase 2 plan** (per `writing-plans` skill)
9. **Build Phase 2** (subagent-driven or in-controller)

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
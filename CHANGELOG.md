# Changelog

All notable changes to Tangent.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- STATUS.md tracks session-by-session progress
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

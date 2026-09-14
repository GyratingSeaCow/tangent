# Tangent — Voice Brain Dump for ADHD

> **Talk. We remember.**
> Voice notes → searchable text → your second brain.
> Built for ADHD minds. Self-hosted. Offline-first. No subscriptions.

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![Client tests: 91 passing](https://img.shields.io/badge/client_tests-91%20passing-brightgreen.svg)]()

---

## What is this?

**Tangent** is a voice-first brain dump app for people whose brains outpace their
fingers. You tap a big red button, ramble for 30 seconds or 30 minutes, and the app:

1. **Saves the recording locally** on your device — always, even offline
2. **Lets you play and seek it** directly in the Dump detail
3. **Transcribes it locally** on Android with checksum-verified Whisper large-v3
4. **Indexes the text** for full-text search
5. **Optionally syncs to your server** when the network returns

**Two recording modes:**

- **Brain Dump** — unstructured voice memo, transcribed verbatim
- **Meeting** — secretary mode, post-processed into `# Meeting Summary / Action Items / Transcript`

It's the voice-capture + searchable-archive piece that no current app gets right for ADHD
users. The closest competitors (Otter, Plaud, Audionotes) all charge monthly fees,
lock you to their cloud, and were never designed for how ADHD brains actually work.

---

## Quick start

### Optional sync server

```bash
git clone https://github.com/GyratingSeaCow/tangent.git
cd tangent/server
pip install -e ".[dev]"

# Run
python -m uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
```

On first run, the server prints a setup URL. Visit it (or curl it) to get an API token:

```bash
curl -X POST http://localhost:8000/v1/setup \
  -H "Content-Type: application/json" \
  -d '{"display_name": "You"}'
# → {"token": "abc...", "display_name": "You", ...}
```

**Save the token** — it's only shown once.

#### Docker (production)

```bash
cd server
docker compose up -d
```

### Client (sideload APK on Android)

Build the APK:

```bash
export JAVA_HOME="C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot"  # Windows example
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
cd client
flutter build apk --debug
# Output: client/build/app/outputs/flutter-apk/app-debug.apk
```

Install:

```bash
adb install -r client/build/app/outputs/flutter-apk/app-debug.apk
```

On first launch:

1. Tap "Get started"
2. Authorize Documents or the existing Tangent recording folder
3. Start talking — big red mic button on the home screen
4. Review recordings with the in-app player and draggable seek bar
5. Download the checksum-pinned large-v3 model once, then transcribe offline

Server URL and token configuration is optional and only enables replication to a server you control.

### Desktop (Linux)

Build (must be on a Linux host — Flutter doesn't cross-compile desktop):

```bash
cd client
flutter build linux
# Output: client/build/linux/x64/release/bundle/tangent
```

---

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│ Tangent Client (Flutter — Android / Linux / Windows)         │
│                                                              │
│  Mic button ──► opus recording (16kHz mono, ~32kbps)         │
│       │                                                      │
│       ▼                                                      │
│  Local playback + seek + Android whisper.cpp large-v3       │
│       │                                                      │
│       ▼                                                      │
│  Local transcript persistence + SQLite FTS5 search          │
│       │                                                      │
│       ▼                                                      │
│  Optional sync ──► upload to server when configured          │
└──────────────────────┬───────────────────────────────────────┘
                       │ HTTPS
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ Tangent Server (FastAPI + SQLite + faster-whisper)          │
│                                                              │
│  /v1/dumps         POST/GET/PATCH/DELETE (CRUD)              │
│  /v1/dumps/{id}/audio POST (multipart) / GET (download)      │
│  /v1/dumps/{id}/transcribe POST (enqueue job)               │
│  /v1/jobs/{id}     GET (poll status)                         │
│  /v1/jobs/{id}/stream GET (Server-Sent Events)               │
│  /v1/setup         POST (first-run token generation)         │
│  /v1/server/info   GET (version, model list, storage stats)  │
│  /v1/models        GET (list), POST /pull (download model)   │
│                                                              │
│  Storage: <data_dir>/tangent.db + <data_dir>/audio/*.opus    │
└──────────────────────────────────────────────────────────────┘
```

### Privacy & data ownership

- **Audio never leaves your device unless you sync to a server you control.**
- Server stores audio as plain `.opus` files under `<data_dir>/audio/{dump_id}.opus`.
- The token in the client is stored in **Android Keystore** via `flutter_secure_storage`
  (encrypted at rest with AES-GCM, key in hardware-backed keystore).
- No analytics, no telemetry, no third-party calls. AGPL-3 means if anyone runs a public
  fork of the server, they have to publish their changes.

---

## v1 feature checklist

| Feature | Status |
|---|---|
| Voice recording (opus, 16kHz mono) | ✅ Android, Linux, Windows |
| Local-first storage (always saves first) | ✅ |
| SQLite with FTS5 full-text search | ✅ |
| Server upload (multipart, idempotent) | ✅ |
| In-app recording playback + seek bar | ✅ |
| On-device Android Whisper large-v3 transcription | ✅ physical local transcription verified |
| Persistent progress panel + active clip indicator | ✅ |
| **Brain Dump mode** (verbatim transcript) | ✅ |
| **Meeting mode** (action items + summary) | ✅ |
| Real-time job updates (Server-Sent Events) | ✅ |
| Sync engine with retry + failure tracking | ✅ |
| Batched "Confirm to Transcribe All" notification | ✅ (the Sync button on home) |
| Server-side audio download | ✅ |
| Token-based auth (hashed, single-user) | ✅ |
| Self-hosted Docker Compose | ✅ |
| AGPL-3 license | ✅ |
| Folder/tag organization | ❌ v2 |
| Encryption at rest for audio | ❌ v2 |
| Multi-device sync | ❌ v2 |
| Speaker diarization | ❌ v2 |

---

## Development

### Run all tests

```bash
# Server (Python)
cd server
python -m pytest                # 61 unit + 1 live integration

# Client (Flutter)
cd client
flutter test                    # 91 widget + unit tests
flutter analyze                 # 0 errors
```

### Project layout

```
tangent/
├── server/                  # FastAPI + SQLite + Whisper backend
│   ├── app/
│   │   ├── api/             # HTTP endpoints
│   │   ├── services/        # transcription, job_queue, storage, secretary
│   │   ├── db.py            # SQLite schema + connection management
│   │   └── main.py          # create_app() factory + lifespan
│   ├── tests/               # pytest
│   └── docker-compose.yml
├── client/                  # Flutter app (Android / Linux / Windows)
│   ├── lib/
│   │   ├── data/            # local_db, audio_storage, secure_storage, settings
│   │   ├── models/          # domain types (Dump, SyncStatus, DumpMode)
│   │   ├── services/        # recording, sync, transcription client, connectivity
│   │   └── screens/         # home, dumps list/detail, server config, settings
│   └── test/
├── docs/                    # design specs + implementation plans
├── STATUS.md                # session-by-session project state
├── AGENTS.md                # agent instructions (subagent-driven dev)
└── CONTRIBUTING.md
```

### Architecture decisions

- **Why self-hosted?** Cloud-locked voice apps fail at the moment users need them most
  (sub goes up, service shuts down, rate limit hit). Tangent is a single Docker container
  on a Raspberry Pi if you want it to be.
- **Why SQLite?** Single-user, single-binary deployment. No "did you forget to start
  Postgres?" tax. WAL mode lets us have async reads + writes.
- **Why faster-whisper?** CTranslate2 backend is 4× faster than OpenAI's reference
  implementation. Runs large-v3 on a CPU at reasonable speed.
- **Why Flutter?** Same UI codebase runs on Android + Linux + Windows. ADHD users live
  on phones; the dev lives on Windows. Both deserve first-class support.

---

## License

[AGPL-3.0](./LICENSE). Self-hosted = source-available. If you fork it and run a public
service, you have to publish your changes. That's the whole point.

## Acknowledgments

- **r/ADHD** — for the years of "I just want an app that…" threads that made the gap obvious
- **r/selfhosted** — for proving the offline-first community is real and growing
- **whisper.cpp / faster-whisper** — for making local Whisper inference actually work
- **Immich** — for showing the world what a self-hosted, community-loved app looks like

---

*Built by one ADHD developer. v1 ships; v2 starts whenever.*

# Tangent — Voice Brain Dump for ADHD

> **Talk. We remember.**
> Voice notes → searchable text → your second brain.
> Built for ADHD minds. Self-hosted. Offline-first. No subscriptions.

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![Client tests: 978 passing](https://img.shields.io/badge/client_tests-978%20passing-brightgreen.svg)]()
[![Server tests: 125 passing](https://img.shields.io/badge/server_tests-125%20passing-brightgreen.svg)]()

---

## What is this?

**Tangent** is a voice-first brain dump app for people whose brains outpace their
fingers. You tap a big red button, ramble for 30 seconds or 30 minutes, and the app:

1. **Saves the recording locally** on your device — always, even offline
2. **Lets you play and seek it** directly in the Dump detail
3. **Transcribes it on your own server** with Whisper large-v3, when you point
   the app at one (see [Optional sync server](#optional-sync-server))
4. **Indexes the text** for full-text search
5. **Keeps everything on the device** until you choose to transcribe

> **Transcription requires a server you run.** There is no on-device
> transcription and no third-party cloud: recording, playback, notebooks and
> search all work fully offline, but turning speech into text means running the
> bundled server yourself (Docker one-liner below) and pointing the app at it.

**Three capture modes:**

- **Brain Dump** — unstructured voice memo, transcribed verbatim
- **Meeting** — secretary mode, post-processed into `# Meeting Summary / Action Items / Transcript`
- **Text Note** — typed straight in, no recording

**Notebooks** give you an endless scrolling page where handwriting, typed
blocks and your recordings live side by side — drag a recording onto the page,
write around it, and tap it to play it back.

**Import audio** pulls an existing file (a voice memo from another app, a
meeting recording someone sent you) into Tangent and treats it like anything
you recorded yourself.

It's the voice-capture + searchable-archive piece that no current app gets right for ADHD
users. The closest competitors (Otter, Plaud, Audionotes) all charge monthly fees,
lock you to their cloud, and were never designed for how ADHD brains actually work.

---

## Quick start

### Prerequisites

| To run | You need |
|---|---|
| **Server** (needed only for transcription) | Docker, **or** Python ≥ 3.11 |
| **Android app** | [Flutter ≥ 3.27](https://docs.flutter.dev/get-started/install) (Dart ≥ 3.6), JDK 17, Android SDK + `adb` |
| **Linux desktop app** | Flutter ≥ 3.27 on a Linux host, plus `clang`, `cmake`, `ninja-build`, `libgtk-3-dev` |

`flutter doctor` tells you what is still missing for the client build. Docker is
by far the easiest way to run the server — it needs no Python setup at all.

### Optional sync server

**Docker (recommended — no Python setup):**

```bash
git clone https://github.com/GyratingSeaCow/tangent.git
cd tangent/server
docker compose up -d
```

**From source:**

```bash
git clone https://github.com/GyratingSeaCow/tangent.git
cd tangent/server

python -m venv .venv                 # do not install into system Python
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -e ".[dev]"

python -m uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000
```

On first run the server prints a setup URL. Call it once to mint an API token:

```bash
# Docker publishes the server on host port 8765:
curl -X POST http://localhost:8765/v1/setup \
  -H "Content-Type: application/json" \
  -d '{"display_name": "You"}'

# Running from source with the command above, it is on 8000:
curl -X POST http://localhost:8000/v1/setup \
  -H "Content-Type: application/json" \
  -d '{"display_name": "You"}'

# → {"token": "abc...", "display_name": "You", ...}
```

**Save the token** — it is only shown once. Put it, and the server's URL, into
the app under **Settings → Server**.

> The container listens on 8000 internally and `docker-compose.yml` maps it to
> **8765** on the host. Change the left-hand number there if you want a
> different host port.

### Client (sideload APK on Android)

Build the APK:

```bash
cd client
flutter pub get
flutter build apk --debug
# Output: client/build/app/outputs/flutter-apk/app-debug.apk
```

If Gradle cannot find a JDK, point it at one explicitly — use forward slashes
on Windows so the path survives the shell:

```bash
export JAVA_HOME="C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot"
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
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
5. To transcribe, open **Settings → Server**, enter your server's URL and the
   token it printed at setup, then tap **Transcribe** on any recording

Recording, playback, notebooks and search need no server at all. Only
transcription does.

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
│  Local playback + seek + notebooks + FTS5 search            │
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
| Transcription via your own server (Whisper large-v3) | ✅ device-verified |
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
| Notebooks (handwriting + typed blocks + embedded recordings) | ✅ |
| Import existing audio files | ✅ |
| Text notes | ✅ |
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
python -m pytest                # 125 passed, 1 skipped

# Client (Flutter)
cd client
flutter test                    # 978 widget + unit tests
flutter analyze                 # No issues found

# Android native (Kotlin) — from client/android
./gradlew :app:testDebugUnitTest
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
├── docs/                    # design + verification notes
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

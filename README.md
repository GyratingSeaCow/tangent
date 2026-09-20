# Tangent — Voice Brain Dump for ADHD

> **Talk. We remember.**
> Voice notes → searchable text → your second brain.
> Built for ADHD minds. Self-hosted. Offline-first. No subscriptions.

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![Version: 1.3.0](https://img.shields.io/badge/version-1.3.0-blue.svg)](./CHANGELOG.md)
[![Client tests: 1397 passing](https://img.shields.io/badge/client_tests-1397%20passing-brightgreen.svg)]()
[![Server tests: 180 passing](https://img.shields.io/badge/server_tests-180%20passing-brightgreen.svg)]()

---

## What is this?

**Tangent** is a voice-first brain dump app for people whose brains outpace their
fingers. You tap a big red button, ramble for 30 seconds or 30 minutes, and the app:

1. **Saves the recording locally** on your device — always, even offline
2. **Lets you play and seek it** directly in the Dump detail
3. **Transcribes it on your own server** with Whisper large-v3, when you point
   the app at one (see [Server setup](#server-setup))
4. **Indexes the text** for full-text search
5. **Keeps everything on the device** until you choose to transcribe

> **Transcription requires a server you run.** There is no on-device
> transcription and no third-party cloud: recording, playback, notebooks and
> search all work fully offline, but turning speech into text means running the
> bundled server yourself (Docker one-liner below) and pairing the app with it.

**Three capture modes:**

- **Brain Dump** — unstructured voice memo, transcribed verbatim
- **Meeting** — secretary mode, post-processed into `# Meeting Summary / Action Items / Transcript`
- **Text Note** — typed straight in, no recording

**Notebooks** give you an endless scrolling page where handwriting, typed
blocks and your recordings live side by side — drag a recording onto the page,
write around it, and tap it to play it back. Handwriting is pressure-aware
with a **pen-style picker** (uniform, fountain, italic nib), palm rejection,
a stroke eraser, **multi-step undo/redo**, and a **smart lasso** that
circle-selects ink, text blocks and recording cards together so you can drag
or delete them as one. Backing out of any editor **saves automatically** —
the back button never discards work. File notebooks into **folders**,
collapse a folder by tapping its name, and switch between a named list and a
cover-grid view.

**Multi-device sync** keeps notebooks, notes and recordings consistent across
your devices through the server: each device pairs once (a 6-digit code, no
token copying), then pushes and pulls changes with per-device change
tracking.

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
| **Server** (needed only for transcription + sync) | Docker, **or** Python ≥ 3.11 |
| **Android app** | [Flutter ≥ 3.27](https://docs.flutter.dev/get-started/install) (Dart ≥ 3.6), JDK 17, Android SDK + `adb` — or just sideload the release APK |
| **Linux desktop app** | Flutter ≥ 3.27 on a Linux host, plus `clang`, `cmake`, `ninja-build`, `libgtk-3-dev` |

`flutter doctor` tells you what is still missing for the client build. Docker is
by far the easiest way to run the server — it needs no Python setup at all.

### Server setup

**Prebuilt image from GHCR (easiest — no clone, no build):**

```bash
docker run -d --name tangent-server \
  -p 8765:8000 \
  -v tangent-data:/data \
  --restart unless-stopped \
  ghcr.io/gyratingseacow/tangent-server:latest
```

**Docker Compose (builds locally, more knobs):**

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

Run first-run setup **once** to name the server and mint its primary token:

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

**Save the token somewhere safe** — it is only shown once, and it is the
server's primary credential. But you no longer need to type it into your
devices: they pair instead (next section).

> The container listens on 8000 internally and `docker-compose.yml` maps it to
> **8765** on the host. Change the left-hand number there if you want a
> different host port.

### Client (Android)

**Easiest: download the APK from [Releases](https://github.com/GyratingSeaCow/tangent/releases)**
and sideload it (`adb install -r tangent-vX.Y.Z.apk`, or just open the file on
the phone). No toolchain needed. Releases from v1.3.0 onward are signed with
the project's release key; Android may still warn about installing from
outside Play, which is normal for sideloaded apps. If you previously
installed a locally-built (debug-signed) copy, uninstall it once before
installing a release APK — the signatures differ.

**Or build it yourself:**

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
5. To transcribe or sync, connect the app to your server (next section)

Recording, playback, notebooks and search need no server at all. Only
transcription and multi-device sync do.

### Connecting the app to your server (pairing)

The app finds your server and earns its own credential — no URL typing, no
token copying:

1. On the device, open **Settings → Server** and tap **Find my server**. The
   app sweeps your local network and lists every Tangent server it finds
   (name, address, version) within a few seconds.
2. Tap **Pair** next to your server.
3. The server prints a **6-digit code** to its log. Read it there:

   ```powershell
   # Windows PowerShell:
   docker compose -f path\to\tangent\server\docker-compose.yml logs tangent-server --since 2m | Select-String code_issued
   ```

   ```bash
   # Linux/macOS:
   docker compose logs tangent-server --since 2m | grep code_issued
   ```

4. Type the code into the app. Done — the device now holds its own token and
   is fully connected.

**Why a code?** It proves you control the server, not just its network. The
code is never sent to the requesting device, expires in **120 seconds**, is
stored only as a hash, and dies after 5 wrong attempts. Each device gets its
own revocable token, so a lost phone can be cut off without re-pairing
everything else:

```bash
curl -X DELETE http://localhost:8765/v1/devices/<device-id>/token \
  -H "Authorization: Bearer <any-valid-token>"
```

**Manual fallback:** the same screen still accepts a URL + token directly —
use this when the server is reachable but not on your local subnet (e.g.
over **Tailscale** or another VPN, where the network sweep can't see it).
Enter `http://<server-address>:8765` plus the token from setup.

> **Note for pairing:** tap Pair on the device *first*, then read the log —
> the code is only generated when the device asks, and it expires quickly.

### Desktop (Linux)

Build (must be on a Linux host — Flutter doesn't cross-compile desktop):

```bash
cd client
flutter build linux
# Output: client/build/linux/x64/release/bundle/tangent
```

---

## Updating

### Server

```bash
# GHCR image:
docker pull ghcr.io/gyratingseacow/tangent-server:latest
docker stop tangent-server && docker rm tangent-server
# then re-run the docker run command from Server setup (the volume keeps your data)

# Docker Compose:
cd tangent/server
git pull
docker compose up -d --build
```

Database migrations run automatically on startup; your data directory
(`./data` or the `tangent-data` volume) survives every update. Paired
devices stay paired — tokens live in the database, not the container.

### Android app

Install the new APK over the old one — data is kept:

```bash
adb install -r tangent-vX.Y.Z.apk     # or open the APK on the phone
```

> **After every reinstall, Android revokes the storage folder grant.** The
> first time you open the app after updating, re-authorize the Tangent
> folder when prompted (about 10 seconds). This is Android's Storage Access
> Framework behavior, not a bug.

Debug and release builds are signed differently — switching between them
requires a one-time uninstall, which deletes local data. Stick to one flavor.

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
│  Optional sync ──► upload/pull changes when paired           │
└──────────────────────┬───────────────────────────────────────┘
                       │ HTTP(S), device-bound bearer token
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ Tangent Server (FastAPI + SQLite + faster-whisper)          │
│                                                              │
│  /v1/server/info/public GET (unauthenticated discovery)      │
│  /v1/pair/request  POST (open pairing; code goes to the log) │
│  /v1/pair/claim    POST (code → device-bound token)          │
│  /v1/pair/pending  GET  (pending pairings, for authed UIs)   │
│  /v1/devices/{id}/token DELETE (revoke one device)           │
│  /v1/devices       POST (register), /v1/sync/pull + /push    │
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
- Tokens in the client are stored in **Android Keystore** via `flutter_secure_storage`
  (encrypted at rest with AES-GCM, key in hardware-backed keystore).
- Pairing codes are stored **hashed** on the server and never transmitted to
  the requesting device; each device holds its own revocable token.
- The unauthenticated discovery endpoint reveals only the server's name,
  version and that auth is required — no data, counts, or configuration.
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
| Server-side audio download (single + bulk, playable) | ✅ device-verified |
| Bulk transcribe from the selection toolbar | ✅ |
| Token-based auth (hashed, single-user, per-device tokens) | ✅ |
| Self-hosted Docker Compose | ✅ |
| Notebooks (handwriting + typed blocks + embedded recordings) | ✅ |
| Notebook folders with collapsible sections (list + cover views) | ✅ |
| Pen styles (uniform / fountain / italic nib), pressure-aware | ✅ device-verified |
| Palm rejection + stroke eraser | ✅ device-verified |
| Smart lasso (ink + blocks + recordings; drag, delete) | ✅ device-verified |
| Multi-step undo/redo | ✅ device-verified |
| Save-on-back everywhere (back never discards) | ✅ |
| Import existing audio files | ✅ |
| Text notes | ✅ |
| Speaker diarization (server, pyannote) | ✅ optional, off by default |
| **Multi-device sync** (notebooks, notes, recordings) | ✅ |
| **Server discovery + pairing** (subnet sweep, 6-digit code) | ✅ device-verified |
| Encryption at rest for audio | ❌ v2 |

---

## Development

### Run all tests

```bash
# Server (Python)
cd server
python -m pytest                # 180 passed, 1 skipped

# Client (Flutter)
cd client
flutter test                    # 1397 widget + unit tests
flutter analyze                 # No issues found

# Android native (Kotlin) — from client/android
./gradlew :app:testDebugUnitTest
```

### Project layout

```
tangent/
├── server/                  # FastAPI + SQLite + Whisper backend
│   ├── app/
│   │   ├── api/             # HTTP endpoints (incl. pairing, sync)
│   │   ├── services/        # transcription, job_queue, storage, secretary
│   │   ├── db.py            # SQLite schema + connection management
│   │   └── main.py          # create_app() factory + lifespan
│   ├── tests/               # pytest
│   └── docker-compose.yml
├── client/                  # Flutter app (Android / Linux / Windows)
│   ├── lib/
│   │   ├── data/            # local_db, audio_storage, secure_storage, settings
│   │   ├── models/          # domain types (Dump, SyncStatus, DumpMode)
│   │   ├── services/        # recording, sync, discovery, pairing, transcription
│   │   └── screens/         # home, dumps, notebooks, server config, settings
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
- **Why client-side discovery?** The server usually runs in a bridged Docker
  container whose mDNS announcements would carry an unreachable container IP.
  The client sweeping its own /24 works identically for Docker, bare-metal
  and Raspberry Pi deployments, and needs zero server-side network setup.
- **Why pairing codes instead of QR/token copy?** Reading a code off the
  server's own output proves administrative access to the machine — a guest
  on your Wi-Fi can reach the port but can never see the code.

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

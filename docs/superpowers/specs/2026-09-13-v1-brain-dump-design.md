# Tangent v1 — Brain Dump Voice App — Design Spec

> **Status:** v1 design — awaiting user review before implementation planning.
> **Date:** 2026-09-13
> **Authors:** Jeff West (GyratingSeaCow) + Hermes brainstorming session
> **License:** AGPL-3.0

---

## 1. What is Tangent?

Tangent is a **self-hosted, offline-first voice brain-dump app** built for ADHD brains. The user taps a big red button, ramble for anywhere from 30 seconds to 60 minutes, and the app:

1. **Captures audio locally** on the device (always, even offline)
2. **Transcribes it** with on-device Whisper (`small` model, ~460 MB) — instant, offline
3. **Optionally upgrades the transcript** using the user's self-hosted server with Whisper `large-v3` — async, when network available
4. **Indexes the text** for full-text search
5. **Syncs** to the user's server with a batched "Confirm to Transcribe All" notification

**Tagline:** *"Go on a tangent."*

**Why this name:** A tangent is a thought that branches off, gets explored, then comes back. That's exactly what brain-dump UX should feel like — no judgment, no structure, just capture.

---

## 2. Why does this exist?

Three converging gaps in the current app landscape:

1. **Voice-capture apps for ADHD users are cloud-locked and expensive.** Otter, Plaud, Audionotes charge $10–30/mo. Every "best ADHD app" Reddit thread names voice capture as the top need.
2. **Self-hostable everything is a growing demand.** The "anti-cloud" trend shows up in ~7% of "I wish this existed" posts on Reddit. People want local-first tools.
3. **No existing app combines all three of: voice capture + searchable text + self-hostable + offline-first.** Each piece exists in isolation. The intersection is empty.

**Existing collisions (verified):**

| Name | Status | Verdict |
|---|---|---|
| Yapper | App Store + Play Store (×2 apps) | ❌ Avoid |
| Braintoss | App Store + Play Store since 2015, $3.49 | ❌ Avoid (same product pitch) |
| Tangent Notes | iOS, open source, markdown notes | ⚠️ Adjacent (different product — markdown, not voice) |
| `tangent-app` on npm | Not registered | ✅ Available |
| `tangent-app` on PyPI | Not registered | ✅ Available |

**The Tangent / Tangent Notes collision is acceptable** because the products are visibly different (voice-first vs. markdown-first), and discoverability for our audience (r/ADHD, r/selfhosted) flows through community channels that disambiguate clearly.

---

## 3. Goals & Non-Goals

### v1 Goals

- A user can install Tangent on a fresh Android phone and dump their first thought within 60 seconds, with no network, no account, no server.
- A user with a homelab can run `docker compose up` and have their dumps auto-sync to a server with bigger-model transcripts.
- All user data stays on the user's device and (optionally) the user's server. Nothing leaves the network.
- The app earns enough recognition on r/ADHD and r/selfhosted that v2 features get community pull requests.

### v1 Non-Goals

- Folders, tags, pinning, color-coding, multi-select batch ops.
- Auto-routing dumps to Trello / Todoist / Calendar / Slack.
- Body-double nudger, meal tracking, calendar awareness, hyperfocus-break reminders.
- Cloud sync across devices.
- Encryption at rest with key management.
- Speaker diarization on-device (heuristic labels only — see §6).
- Web UI for the server (CLI + REST API only).
- Multi-user server (single-user, single-token).
- iOS support (Flutter code is cross-platform-ready but iOS build/test deferred to v2).

---

## 4. Architecture

### High-level

```
┌─────────────────────────────────────────────────────────────┐
│ Tangent Client (Flutter, Android / Linux / Windows)        │
│ • Record button → Opus/AAC audio → SQLite + audio file      │
│ • Auto-transcribe via on-device Whisper (instant)            │
│ • Local FTS5 search                                          │
│ • Sync engine: detect connectivity → batch upload → server  │
│ • Optional: secretary mode (on-device LLM for meeting notes)│
└──────────────────────┬──────────────────────────────────────┘
                       │ HTTPS, Bearer token auth
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ Tangent Server (Docker Compose)                             │
│ • FastAPI + SQLite (single user, single binary)             │
│ • whisper-large-v3 with pyannote speaker diarization        │
│ • Async transcription jobs (Celery or FastAPI background)   │
│ • Server-Sent Events for job completion notifications       │
│ • nginx optional reverse proxy for TLS                      │
└─────────────────────────────────────────────────────────────┘
```

### Client tech stack

- **Flutter** (Dart) — single codebase, Android / Linux / Windows
- **whisper.cpp** for on-device Whisper inference (C++ via FFI)
- **llama.cpp** for on-device LLM inference (Gemma 2B / Phi-3-mini Q4) — secretary mode only
- **SQLite + FTS5** for local storage and full-text search
- **flutter_sound** or **record** package for audio capture
- **dio** for HTTP client

### Server tech stack

- **FastAPI** (Python 3.11+)
- **SQLite** for metadata storage (dumps, jobs, model state)
- **faster-whisper** (CTranslate2-wrapped Whisper large-v3)
- **pyannote-audio** for speaker diarization
- **Server-Sent Events** (built into FastAPI/Starlette) for job notifications
- **Docker Compose** for one-command deploy

### Sync protocol

1. **Client uploads dumps** as soon as they exist (when network available). Each dump carries a client-generated UUID.
2. **Server deduplicates** by UUID — same UUID = already have it, no-op.
3. **Transcription jobs** are queued server-side, processed with `large-v3` + diarization.
4. **Server emits SSE event** when job completes with the upgraded transcript.
5. **Client patches local copy** with server's transcript — server wins on accuracy.
6. **Audio files stay on the phone** — server doesn't need them once transcribed.

**Conflict resolution: client is source of truth for content, server mirrors it.** Single-user self-hosted — server is essentially a backup + bigger-model transcription service, not a separate authoring surface. Append-only event log + periodic snapshots.

---

## 5. Authentication

**API token, generated server-side at first launch.**

Setup flow:
1. User runs `docker compose up`
2. Server starts and prints to stdout: `http://homelab.lan:8000/setup?token=xyz`
3. User opens the URL in any browser
4. Browser UI: enter display name → generate long-lived API token
5. User copies token, pastes into Tangent app Settings → "Server URL & Token"
6. Token stored in Android Keystore / Linux secret service / Windows Credential Manager

**No passwords, no account system, no OAuth.** Single user, single token.

---

## 6. On-device models

| Model | Size | Purpose | Required for |
|---|---|---|---|
| **Whisper `small`** | ~460 MB | Speech-to-text | All dumps (default) |
| **Whisper `small.en`** | ~460 MB | English-only STT, faster | Optional upgrade (English speakers) |
| **Whisper `medium`** | ~1.5 GB | Better accuracy | Optional upgrade |
| **Whisper `large-v3`** | ~3 GB | Best accuracy (server-side only) | Server only, never downloaded to phone |
| **Gemma 2B / Phi-3-mini Q4** | ~1.5–2.5 GB | Meeting summarization | Secretary mode only |

**Model manager screen:**

```
┌─────────────────────────────────────────────────────────────┐
│  Models                                              [←] │
│                                                              │
│  Active speech model                                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Whisper small · 460 MB · ✓ Downloaded           │ │
│  │ Multilingual. Good for most brain dumps.               │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Need more accuracy? Download a bigger model!                │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Whisper small.en · 460 MB · ⚡ Faster (English only)  │ │
│  │ [Download · 460 MB]                                    │ │
│  ├────────────────────────────────────────────────────────┤ │
│  │ Whisper medium · 1.5 GB · 🎯 More accurate      │ │
│  │ [Download · 1.5 GB · ~12 min on Wi-Fi]                │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Meeting notes model (secretary mode)                        │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Gemma 2B · 1.8 GB · Required for secretary mode │ │
│  │ Not downloaded                                         │ │
│  │ [Download · 1.8 GB · ~14 min on Wi-Fi]                │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Honest callouts in the model manager:**
- Every download shows: file size, estimated download time on Wi-Fi, battery impact ("uses ~5% battery per 30 min")
- The "Need more accuracy?" prompt appears immediately under the active model — never as a nag, never as a popup
- Models can be deleted to free storage: long-press a model row → Delete

---

## 7. First-launch onboarding

**Goal:** User can record their first dump within 60 seconds of installing.

```
Screen 1 (instant)
──────────────────
Big title: "Tangent"
Subtitle: "Go on a tangent."
Single button: [Get Started →]

Screen 2 (1 tap, instant)
──────────────────────────
"We need your microphone."
Single button: [Allow Microphone]
→ Android system permission dialog appears

Screen 3 (skippable, 1 tap)
────────────────────────────
"Got a self-hosted server?"
Sub: "Optional. Skip to use on-device only."
[Skip]  or  [Add Server URL]
If Add → URL field + paste API token field

→ Lands on home screen
• Model downloads silently in background (Whisper small, ~460 MB)
• Huge red Record button centered
• Today's dumps count below button
```

**Design choices:**
- **3 screens max** before recording is possible
- **No model picker on first launch** — small is the default; upgrade happens in Settings → Models
- **No legal copy** — license + privacy live in Settings → About
- **Server URL optional** — defaults to standalone mode
- **Recordings before model finishes downloading** are queued locally and transcribed when model arrives

---

## 8. Recording screen

```
┌─────────────────────────────────────────────────────────────┐
│                         2:47                                │
│                                                              │
│                                                              │
│                  ┌───────────────────────┐                  │
│                  │                       │                  │
│                  │                       │                  │
│                  │      [   ●  ]         │                  │
│                  │                       │                  │
│                  │                       │                  │
│                  └───────────────────────┘                  │
│                                                              │
│                  ━━━━━━━━━━━━━━━━━━━━━━                    │
│                  ▌▌▌▌▌▌▓▓▓▓▓▒▒▒▒▒░░░                          │
│                                                              │
│                  Today's dumps: 4                            │
└─────────────────────────────────────────────────────────────┘
              (thin red border around whole screen while recording)
```

### Recording modes

| Mode | Where it lives | When it runs | Output |
|---|---|---|---|
| **Brain Dump** | Main recording button | Always available | Raw transcript + audio file |
| **Secretary Mode** | Menu → "New Meeting Notes" | Long recording (up to 60 min) | Structured Markdown: Summary / Speakers / Action Items / Decisions / Timestamped transcript |

**Both modes share:** recording UI, audio capture, audio storage, 60-min hard cap.

### Recording trigger

| Setting | Default | Notes |
|---|---|---|
| Tap to start / tap to stop | ✅ Default | Best for ADHD use case — user can drop their phone and keep talking |
| Hold to record | Optional toggle in Settings | For users who want walkie-talkie-style burst capture |

### Visual feedback

- **Big mm:ss time counter** at top
- **Live level meter** (animated, mic-reactive, no full waveform) — proves the mic hears you
- **Thin red border** around whole screen — impossible to miss peripherally
- **Pulsing red circle button** in center
- **Today's dumps: N** at bottom

### Button states

| State | Look |
|---|---|
| **Idle** | Solid red circle with white mic icon, gentle pulse animation |
| **Recording** | Solid red, square stop icon in middle, screen border lights red |
| **Saving** | Brief green flash, button becomes checkmark for 3 sec, then returns to idle |

### Post-recording flow

1. Audio file finalized (Opus/AAC, mono, 16kHz)
2. Stored locally with timestamp + auto-generated title (first ~6 words of transcript)
3. Toast appears: "Saved · 3:12 — searching when network returns"
4. **Background:** on-device Whisper transcribes immediately (if model ready)
5. **Background:** if server reachable, upload queued for batch sync
6. After 3 sec: toast fades, screen returns to idle

**The post-recording card has a small "Transcribe" button** (your spec) — for users who skipped auto-transcription (e.g. model not downloaded yet) and want to retry immediately.

### Max recording length

**60-minute hard cap.** No warning prompts mid-recording. ADHD users hate interruptions mid-thought. The cap exists to prevent storage/battery accidents, not to constrain legitimate use.

### Secretary mode flow

1. User taps menu → "New Meeting Notes" (instead of main record button)
2. Recording starts with same UI + level meter
3. On stop: audio uploaded + transcription job queued (uses on-device Whisper small — no server required for this mode in v1)
4. Post-processing: on-device LLM (Gemma 2B / Phi-3-mini Q4) structures the transcript
5. Output: Markdown document with sections:
   - **Summary** (2–3 sentences)
   - **Speakers** (heuristic labels: "Speaker 1", "Speaker 2" with timestamps)
   - **Action Items** (LLM-extracted bullet list)
   - **Decisions** (LLM-extracted bullet list)
   - **Timestamped Transcript** (full transcript with speaker labels and timestamps)
6. User can edit, copy, share, or export as .md file

**Honest scope note on secretary mode:**
- No real speaker diarization in v1 — heuristic labels only. Quality is "good enough for your own meeting recall," not Otter-grade.
- Requires on-device LLM model download (~1.8 GB) on first use.
- LLM processing: ~5–15 seconds per minute of audio on a modern phone.
- Output quality depends heavily on the chosen LLM; Gemma 2B is the default.
- **Secretary mode is fully on-device in v1.** Even when the server is configured, secretary mode does NOT upload meeting audio for server-side transcription. The server-side `large-v3` + diarization pipeline exists for future v2 enhancement (real speaker labels across multiple devices). In v1, the server handles only brain-dump upgrades.

---

## 9. Dumps list + search screen

```
┌─────────────────────────────────────────────────────────────┐
│  Tangent                                               [⚙]  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ 🔍  Search7 dumps                                  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Filter: [All] [Brain Dump] [Meeting] [⏳ Awaiting sync]    │
│                                                              │
│  ── Today ──────────────────────────────────────────────── │
│                                                              │
│  ⚠ Awaiting sync (3) · tap to batch transcribe              │
│                                                              │
│  📝 "okay so the thing about the deployment is..."           │
│     Brain Dump · 3:47 · 2 min ago · ✓ Synced                │
│     [tap row to open full transcript]                        │
│                                                              │
│  📝 "yeah and then bob said we should push to main..."       │
│     Meeting · 12:04 · yesterday 4:12 PM · ⏳ Awaiting       │
│                                                              │
│  ── Yesterday ──────────────────────────────────────────── │
│                                                              │
│  📝 ... │
└─────────────────────────────────────────────────────────────┘
```

### Dumps list design choices

| Decision | Why |
|---|---|
| Search bar always visible at top | ADHD users search by keyword, not browse |
| Title = first ~6 words of transcript (editable) | Glanceable identity, no extra UI to set titles |
| Filter chips below search | All / Brain Dump / Meeting / Awaiting sync |
| Sectioned by recency — Today / Yesterday / This week / Earlier | Familiar iOS/Android mail pattern |
| "Awaiting sync" banner when items pending | One-tap batch action in-app |
| Status badges per row: ✓ Synced, ⏳ Awaiting, 🔄 Transcribing, ⚠ Failed | Glanceable status |
| Each row shows: title + type + duration + relative time + sync status | One line, scannable |
| Tap row → opens full transcript view | Standard mobile pattern |
| Long-press row → quick actions (rename, delete, re-transcribe, share) | Doesn't clutter main UI |

### Full transcript view (tap a row)

```
┌─────────────────────────────────────────────────────────────┐
│  ← Dumps "okay so the thing about..."           [⋮ Menu]    │
│                                                              │
│  📝 Brain Dump · 3:47 · Sep 13, 2026 at 1:42 PM             │
│  ✓ Synced · [▶ Play audio]                                  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ "okay so the thing about the deployment is — actually │ │
│  │  wait, before that, I need to remember to email Sarah │ │
│  │  about the... yeah. And then the deployment:           │ │
│  │                                                        │ │
│  │  We said we'd push to main on Friday but actually     │ │
│  │  we should wait because Bob said there's a thing      │ │
│  │  with the auth tokens and I don't want to deal with   │ │
│  │  that on a Friday.                                     │ │
│  │                                                        │ │
│  │  Also the meeting at 2 got cancelled."                 │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  [Copy all]  [Share]  [Edit title]  [Re-transcribe]  [Delete]│
└─────────────────────────────────────────────────────────────┘
```

### v1 cuts (intentional)

- Folders, tags, pinning, color-coding, multi-select batch ops
- Auto-summarize view (server-side feature — v2)
- Inline transcript editing
- Cloud sync across devices

---

## 10. Sync & notifications

### Sync engine (client-side)

1. **Detect connectivity change** → trigger sync attempt
2. **Find dumps with `sync_status = "local_only"`** (audio on phone, not on server)
3. **Batch upload** (max 10 at a time, configurable) with retry on failure
4. **For each uploaded dump**, check if server has a better transcript
5. **Patch local transcript** if server transcript exists and is newer
6. **Mark dump as `sync_status = "synced"`**

### Notification UX

**Single notification per sync opportunity** — not per-dump:

```
┌─────────────────────────────────────────────────────────────┐
│  Tangent                                                     │
│  3 recordings awaiting sync                                  │
│                                                              │
│  Estimated upload: ~12 MB                                    │
│  Wi-Fi only: ON                                             │
│                                                              │
│  [Confirm to Transcribe All]              [Later]            │
└─────────────────────────────────────────────────────────────┘
```

**Notification logic:**
- Wi-Fi only by default, toggleable in Settings → Data
- Only fires if `≥1` dump is awaiting sync AND user hasn't already dismissed the notification within the last 6 hours
- Tapping "Confirm to Transcribe All" enqueues all pending dumps
- Tapping "Later" dismisses for 6 hours
- Long-press notification → "Sync over cellular" one-time override

---

## 11. Settings screen

```
┌─────────────────────────────────────────────────────────────┐
│  Settings                                              [←] │
│                                                              │
│  Server                                                      │
│  ──────                                                      │
│  Status: ● Connected                                         │
│  URL: http://homelab.lan:8000                                │
│  [Edit]                                                      │
│                                                              │
│  Recording                                                   │
│  ──────────                                                  │
│  Trigger: ◉ Tap to toggle   ○ Hold to record                │
│                                                              │
│  Transcription                                               │
│  ──────────────                                              │
│  Model: Whisper small · 460 MB                               │
│  [Manage models →]                                           │
│                                                              │
│  Sync                                                        │
│  ────                                                        │
│  Wi-Fi only: ● On                                            │
│  Last sync: 2 min ago                                        │
│                                                              │
│  Data                                                        │
│  ────                                                        │
│  Local storage: 234 MB (342 recordings)                      │
│  [Export all]  [Delete all synced]                           │
│                                                              │
│  About                                                       │
│  ─────                                                       │
│  Version: 1.0.0                                              │
│  License: AGPL-3.0                                           │
│  [View source]  [Privacy policy]                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 12. REST API surface

```
POST   /v1/setup                  → one-time setup, returns API token
POST   /v1/auth/token             → validate token (health check)

GET    /v1/dumps                  → list dumps (paginated, filterable)
POST   /v1/dumps                  → upload new dump (audio + metadata)
GET    /v1/dumps/{id}             → fetch dump + transcript
PATCH  /v1/dumps/{id}             → edit title
DELETE /v1/dumps/{id}             → soft-delete

POST   /v1/dumps/{id}/transcribe  → enqueue transcription job
GET    /v1/jobs/{id}              → poll job status
GET    /v1/jobs/{id}/stream       → SSE stream for completion

GET    /v1/models                 → list available Whisper models
POST   /v1/models/{name}/pull     → server-side: pull a bigger model
GET    /v1/server/info            → version, model status, storage usage
```

All requests authenticated with `Authorization: Bearer <token>`, where `<token>` is the long-lived API token generated during server setup (§5).

---

## 13. Data model

### Client-side SQLite (Tangent app)

```sql
CREATE TABLE dumps (
  id TEXT PRIMARY KEY,           -- client-generated UUID
  created_at INTEGER NOT NULL,   -- unix timestamp
  updated_at INTEGER NOT NULL,
  mode TEXT NOT NULL,            -- 'brain_dump' | 'meeting'
  duration_seconds INTEGER NOT NULL,
  audio_path TEXT NOT NULL,      -- relative path under app data dir
  audio_size_bytes INTEGER NOT NULL,
  title TEXT NOT NULL,           -- first ~6 words of transcript, editable
  transcript TEXT,                -- on-device small model transcript
  server_transcript TEXT,         -- upgraded transcript from server, if any
  transcript_updated_at INTEGER,
  sync_status TEXT NOT NULL,     -- 'local_only' | 'pending' | 'synced' | 'failed'
  sync_attempts INTEGER DEFAULT 0,
  last_sync_error TEXT
);

CREATE VIRTUAL TABLE dumps_fts USING fts5(
  title, transcript, server_transcript,
  content='dumps', content_rowid='rowid'
);

CREATE TABLE models (
  name TEXT PRIMARY KEY,         -- 'whisper-small', 'whisper-medium', 'gemma-2b'
  size_bytes INTEGER NOT NULL,
  downloaded_path TEXT,
  downloaded_at INTEGER,
  is_active INTEGER DEFAULT 0
);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

### Server-side SQLite (Tangent server)

```sql
CREATE TABLE dumps (
  id TEXT PRIMARY KEY,           -- client-generated UUID
  client_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  mode TEXT NOT NULL,
  duration_seconds INTEGER NOT NULL,
  title TEXT NOT NULL,
  transcript TEXT,
  audio_kept INTEGER DEFAULT 0   -- audio deleted after transcription by default
);

CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  dump_id TEXT NOT NULL,
  status TEXT NOT NULL,          -- 'queued' | 'running' | 'completed' | 'failed'
  model TEXT NOT NULL,
  started_at INTEGER,
  completed_at INTEGER,
  result_transcript TEXT,
  error TEXT
);

CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  dump_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
```

---

## 14. Docker server setup

### `docker-compose.yml` (server side)

```yaml
services:
  tangent-server:
    build: ./server
    container_name: tangent-server
    ports:
      - "8000:8000"
    volumes:
      - tangent-data:/data
    environment:
      - TANGENT_DATA_DIR=/data
      - TANGENT_LOG_LEVEL=info
    restart: unless-stopped

volumes:
  tangent-data:
```

### One-command deploy

```bash
git clone https://github.com/GyratingSeaCow/tangent
cd tangent/server
docker compose up -d
# Server prints setup URL to stdout
docker compose logs -f tangent-server
```

---

## 15. Repo layout

```
tangent/                          (this repo)
├── client/                       # Flutter app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── models/               # data models
│   │   ├── services/             # audio, transcription, sync, search
│   │   ├── screens/              # onboarding, recording, dumps, settings
│   │   └── widgets/              # reusable UI
│   ├── android/
│   ├── linux/
│   ├── windows/
│   └── native/                   # whisper.cpp / llama.cpp bindings, JNI/FFI
├── server/                       # FastAPI + Whisper server
│   ├── app/
│   │   ├── main.py
│   │   ├── api/                  # route handlers
│   │   ├── core/                 # config, auth, db
│   │   ├── services/             # transcription, diarization, job queue
│   │   └── models/               # data models
│   ├── tests/
│   ├── Dockerfile
│   └── docker-compose.yml
├── docs/
│   ├── superpowers/
│   │   ├── specs/                # design specs
│   │   └── plans/                # implementation plans
│   └── README.md
├── .gitignore
├── LICENSE                       # AGPL-3.0
├── README.md
├── CONTRIBUTING.md
└── AGENTS.md
```

---

## 16. v1 success criteria

Tangent v1 is "done" when ALL of the following are true, in order:

1. **Solo install works** — A user with no homelab, no server, no account can install the APK, grant microphone permission, and dump their first thought within 60 seconds.
2. **Offline-first works** — Recording and on-device transcription work with airplane mode on. No data leaves the device unless the user explicitly configures a server.
3. **Server mode works** — A user can `docker compose up` the server, generate an API token, paste it into the app, and see dumps sync to the server with `large-v3` transcripts appearing within minutes.
4. **Secretary mode works** — A user can record a 20-minute meeting, end the recording, and get a Markdown summary with action items within 2 minutes (on-device LLM processing time included).
5. **Full-text search works** — A user can find any word they said across all dumps, including dumps that have been synced and re-transcribed by the server.
6. **Settings persist** — Closing and reopening the app preserves all settings, server config, model choices.
7. **AGPL compliance** — All dependencies are AGPL-compatible or permissively licensed. No copyleft-incompatible code.
8. **Private repo state** — Repo stays private until Jeff says "ship it," then flips to public with the AGPL-3.0 license.

---

## 17. Out of scope for v1 (deferred to v2 / v3)

| Feature | Why deferred |
|---|---|
| Folders, tags, organization | Search handles 100% of need for solo users |
| Auto-routing to Trello/Todoist/Calendar | Integration with 3rd-party APIs is its own subsystem |
| Body-double nudger / meal tracking / calendar awareness | Different problem space — Phase 3 |
| Cloud sync across multiple devices | Cross-device sync needs CRDTs or vector clocks |
| Encryption at rest | Key management is its own subsystem |
| Real speaker diarization on-device | Research-grade quality; deferred to v2 |
| Web UI for server | CLI + REST API only for v1 |
| iOS build | Flutter code is cross-platform-ready but iOS-only testing deferred |
| Multi-user server | Single-user self-hosted is the v1 target |
| Push notifications from server | Polling + SSE is enough for single-device |
| Markdown export from brain dumps | Share + copy text covers the immediate need |
| Voice activity detection (auto-stop on silence) | Battery cost; deferred to v2 |
| Background recording (screen off) | Battery cost; deferred to v2 |

---

## 18. Open questions for v2 (not blocking v1)

- Should the server also offer a CLI client (for users who want to dump from the terminal)?
- Should we expose the server as an MCP server so AI agents can query the dump archive?
- Should there be a browser extension that captures audio from any tab and dumps it?
- Should there be a "narrate" feature where Tangent reads your day's dumps back to you in a synthesized voice?

---

## 19. References

- **Reddit threads consulted:**
  - r/ADHD: "What apps actually help you manage daily life?" (50+ upvotes)
  - r/ADHD: "Tools you always recommend to other ADHD folks" (119 points, 91 comments)
  - r/ProductivityApps: "I do not need more motivation, I need an app that works with my brain" (50+ upvotes)
  - r/SaaS: "I analyzed 9,300+ 'I wish there was an app for this' posts" (410 points) — flagged r/ADHD as highest-signal subreddit for app gaps
- **Competitors analyzed:** Otter, Plaud, Audionotes, Yapper (×2), Braintoss, Tangent Notes, Tiimo, Structured, Luma ADHD, Audionotes, Speakwise
- **Open source projects informing architecture:** Immich (self-hosted model), WhisperX (research reference for diarization), llama.cpp (on-device LLM reference)

---

## 20. Sign-off

This spec is the canonical reference for Tangent v1. Any implementation that deviates from this document must update this document first.

**Reviewers:** Jeff West (GyratingSeaCow) — primary author and decision-maker.
**Status:** Awaiting user review.
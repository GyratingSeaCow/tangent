# Tangent v1 — Flutter Client Design Spec (Phase 2)

> **Status:** v1 design — awaiting user review before implementation planning.
> **Date:** 2026-09-13
> **Scope:** Phase 2 of the Tangent v1 build. Server (Phase 1) is shipped; this spec covers the Flutter client that talks to it.
> **License:** AGPL-3.0

---

## 1. What is this?

This is the **client-side** companion to the Tangent server already at `server/` in this repo. The client is a Flutter app that:

1. Captures audio on the user's phone (Android) or desktop (Linux/Windows)
2. Stores recordings locally with full-text searchable transcripts
3. Optionally syncs to a self-hosted Tangent server for bigger-model transcripts
4. Provides a single-user, offline-first experience with no account signup

**Read this together with the server spec** at `docs/superpowers/specs/2026-09-13-v1-brain-dump-design.md` — the API surface (§12) and data model (§13) are defined there and this spec only references them.

---

## 2. Scope decision: A2 (server-side transcription)

This spec adopts **scope path A2**: the Flutter client has **no on-device Whisper integration in v1**. All transcription is done by the server.

**Why this divergence from the original v1 spec:**
- On-device Whisper bindings are research-grade (whisper.cpp JNI/FFI) and a 4-6 day effort on their own
- A working record + upload + transcript-view app can ship today and exercises the full server pipeline
- On-device Whisper is deferred to **Phase 2.5** as a follow-up that doesn't change the public API

**What this means for the user experience:**
- ✅ Works without on-device Whisper (smaller install, no model downloads on first run)
- ❌ Requires the server to be running AND reachable for transcripts to appear
- ❌ No offline transcription (the recording itself is offline; getting text requires server)

This is honest scope. Server users get a real product now; on-device Whisper is the v2 enhancement.

---

## 3. Non-goals (Phase 2)

- On-device Whisper / LLM inference (Phase 2.5+)
- iOS build (Flutter code is cross-platform-ready; iOS-only testing deferred to Phase 3)
- Folder/tag organization, pinning, color-coding
- Auto-routing to Trello/Todoist/Calendar
- Body-double nudger, meal tracking, hyperfocus-break reminders
- Cloud sync across multiple devices
- Encryption at rest with key management
- Web UI for the server
- Push notifications from server (polling is enough for v1)
- Real speaker diarization (heuristic labels only)
- Voice activity detection / auto-stop on silence
- Background recording (screen off)

---

## 4. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Language | **Dart 3.x** | Flutter's native language |
| Framework | **Flutter 3.27+** | Cross-platform mobile + desktop, single codebase |
| State management | **Riverpod** (or Provider) | Modern, testable, recommended by Flutter team |
| Local DB | **drift** (SQLite wrapper) + **FTS5** | Type-safe queries, FTS5 built in |
| HTTP client | **dio** | Interceptors for auth, retry, logging |
| Audio capture | **record** package | Cross-platform, simple API, low-latency |
| Audio playback | **just_audio** | Cross-platform, gapless |
| Local notifications | **flutter_local_notifications** | Sync notifications on Android |
| Secure storage | **flutter_secure_storage** | Wraps Android Keystore / libsecret / Windows Credential Manager |
| Logging | **logger** | Structured logging |
| Path/file ops | **path_provider** + **path** | Standard |
| Date/time | **intl** | Standard |
| UUIDs | **uuid** | For client-generated dump IDs |
| Sync timing | BackgroundTasks (no plugin needed; Flutter handles) | In-app WorkManager-like |

**No on-device Whisper bindings.** No JNI. No CMake. No ggml. Pure Dart packages.

---

## 5. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Tangent Flutter Client                                       │
│                                                               │
│  ┌────────────────┐   ┌────────────────┐   ┌──────────────┐ │
│  │ Recording      │   │ Sync engine    │   │ UI layer     │ │
│  │ service        │   │ (batched)      │   │ (screens)    │ │
│  └───────┬────────┘   └────────┬───────┘   └──────┬───────┘ │
│          │                    │                   │         │
│  ┌───────▼────────────────────▼───────────────────▼───────┐ │
│  │ Local SQLite (drift) + FTS5                             │ │
│  │  - dumps, audio_files, sync_status, settings           │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ HTTP client (dio) → Tangent server REST + SSE          │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Three layers, no UI logic in services, no DB calls in widgets.**

---

## 6. Project layout

```
client/
├── pubspec.yaml
├── analysis_options.yaml
├── README.md
├── lib/
│   ├── main.dart                          # app entry, provider setup
│   ├── app.dart                           # MaterialApp + router
│   ├── models/
│   │   ├── dump.dart                      # domain Dump class
│   │   ├── dump_mode.dart                 # enum brain_dump / meeting
│   │   ├── sync_status.dart               # enum local_only / pending / synced
│   │   ├── server_info.dart
│   │   └── api_exception.dart             # typed error handling
│   ├── data/
│   │   ├── local_db.dart                  # drift database, schema, DAOs
│   │   ├── dumps_dao.dart
│   │   ├── audio_storage.dart             # file path management
│   │   ├── secure_storage.dart            # token storage via keystore
│   │   └── settings_store.dart            # app preferences
│   ├── services/
│   │   ├── recording_service.dart         # mic capture via record package
│   │   ├── playback_service.dart          # audio playback
│   │   ├── transcription_client.dart      # POST /v1/dumps, /v1/jobs/{id}/stream
│   │   ├── sync_engine.dart               # batched uploads, SSE listener
│   │   ├── notification_service.dart       # sync notifications
│   │   ├── connectivity_service.dart      # detect online/offline
│   │   └── logger.dart
│   ├── screens/
│   │   ├── onboarding/
│   │   │   ├── welcome_screen.dart
│   │   │   ├── mic_permission_screen.dart
│   │   │   └── server_setup_screen.dart
│   │   ├── recording/
│   │   │   ├── recording_screen.dart      # big red button + level meter
│   │   │   └── recording_screen_controller.dart  # Riverpod state
│   │   ├── dumps/
│   │   │   ├── dumps_list_screen.dart     # search + filter + list
│   │   │   ├── dump_detail_screen.dart    # full transcript + actions
│   │   │   └── dumps_list_controller.dart
│   │   └── settings/
│   │       ├── settings_screen.dart
│   │       └── settings_controller.dart
│   └── widgets/
│       ├── record_button.dart
│       ├── level_meter.dart
│       ├── dump_list_tile.dart
│       └── sync_status_badge.dart
├── test/
│   ├── unit/
│   │   ├── services/
│   │   │   ├── recording_service_test.dart
│   │   │   ├── transcription_client_test.dart
│   │   │   └── sync_engine_test.dart
│   │   ├── data/
│   │   │   └── local_db_test.dart
│   │   └── models/
│   │       └── dump_test.dart
│   ├── widget/
│   │   ├── recording_screen_test.dart
│   │   └── dumps_list_screen_test.dart
│   └── integration/
│       └── record_to_sync_flow_test.dart  # record → save → upload → show transcript
├── android/
│   ├── app/
│   │   ├── build.gradle
│   │   └── src/main/AndroidManifest.xml   # mic permission
│   └── build.gradle
├── linux/
├── windows/
└── test_driver/                          # E2E tests (later)
```

---

## 7. Data model (client-side drift schema)

```dart
@DataClassName('DumpRow')
class Dumps extends Table {
  TextColumn get id => text()();                       // client-generated UUID
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get mode => text().withLength(min: 1, max: 20)(); // brain_dump | meeting
  IntColumn get durationSeconds => integer()();
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get transcript => text().nullable()();    // null until transcribed
  TextColumn get audioPath => text()();                // absolute path under app docs dir
  IntColumn get audioSizeBytes => integer()();
  TextColumn get syncStatus => text().withLength(min: 1, max: 20)();
  // local_only | pending | syncing | synced | failed
  IntColumn get syncAttempts => integer().withDefault(const Constant(0))();
  TextColumn get lastSyncError => text().nullable()();
}

@DataClassName('SyncQueueRow')
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dumpId => text().references(Dumps, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get queuedAt => dateTime()();
}

@DriftDatabase(tables: [Dumps, SyncQueue])
class LocalDb extends _$LocalDb {
  // FTS5 virtual table for full-text search
  // CREATE VIRTUAL TABLE dumps_fts USING fts5(title, transcript, content='dumps', content_rowid='rowid');
}
```

**Note:** drift's FTS5 support is built-in but requires manual setup. Will create the FTS virtual table in the `onCreate` migration.

---

## 8. API client (talks to server)

All endpoints per `docs/superpowers/specs/2026-09-13-v1-brain-dump-design.md` §12. The client only consumes:

| Endpoint | Purpose | Client behavior |
|---|---|---|
| `POST /v1/setup` | One-time setup | Only used if user provides server URL during onboarding |
| `GET /v1/server/info` | Health/version check | Periodic liveness ping |
| `POST /v1/dumps` | Create dump metadata | Called during sync upload |
| `GET /v1/dumps` | List server dumps | Sync reconciliation (find server-only dumps) |
| `GET /v1/dumps/{id}` | Get dump + transcript | Sync reconciliation |
| `PATCH /v1/dumps/{id}` | Edit title | Sync edits if changed on another device (rare in v1) |
| `DELETE /v1/dumps/{id}` | Soft-delete | Sync deletes |
| `POST /v1/dumps/{id}/transcribe` | Enqueue transcription | Sync engine triggers this on upload |
| `GET /v1/jobs/{id}` | Poll job status | Fallback if SSE fails |
| `GET /v1/jobs/{id}/stream` | SSE for job completion | Primary notification of transcription complete |

**Auth:** all requests include `Authorization: Bearer <token>` where `<token>` is the long-lived API token from setup, stored in OS keystore via `flutter_secure_storage`.

**Error handling:** typed exceptions (`ApiException` with status code + message). On 401, surface "re-enter server URL/token" UI flow.

---

## 9. Recording flow

### Trigger modes

| Setting | Default | Notes |
|---|---|---|
| Tap to start / tap to stop | ✅ Default | Best for ADHD use case — drop phone, keep talking |
| Hold to record | Optional toggle in Settings | Walkie-talkie style for short bursts |

### UI state machine

```
idle (mic available, no recording)
  ↓ tap (or hold-release)
recording (level meter pulsing, red border)
  ↓ tap (or 60-min cap, or stop signal)
saving (green flash, checkmark for 3s)
  ↓
idle
```

### What happens on stop

1. Audio file finalized (Opus 16kHz mono, ~8 KB/sec)
2. File stored at `${appDocs}/audio/{uuid}.opus`
3. Dump row inserted: `sync_status = 'pending'`
4. SyncQueue row inserted
5. Toast: "Saved · 3:12 — uploading when online"
6. Background: SyncEngine picks up the queue

### Max length

**60-minute hard cap.** No mid-recording warnings. Server-side `duration_seconds <= 7200` validation enforces this.

---

## 10. Sync engine

### Detection
- `connectivity_plus` watches network changes
- On `wifi` or `mobile` (if user opted in): trigger sync
- User setting: `sync_over_wifi_only` (default **on**)

### Batch upload
1. Find dumps with `sync_status IN ('pending', 'failed')` AND `sync_attempts < 5`
2. Sort by `created_at ASC` (oldest first)
3. Batch size: **max 10 dumps per sync cycle** (configurable)
4. For each dump:
   - `POST /v1/dumps` with metadata (id, mode, duration, title, created_at)
   - `multipart PUT /v1/dumps/{id}/audio` (real audio upload — added in Phase 2 to server)
   - On success: `sync_status = 'syncing'`
   - `POST /v1/dumps/{id}/transcribe` to enqueue server-side transcription
5. Mark each successful dump `sync_status = 'synced'` after server returns 201

### SSE listener for completion
1. After enqueuing transcription, open `GET /v1/jobs/{id}/stream`
2. Listen for `completed` event with `transcript` payload
3. Update local dump's `transcript` column
4. Show in-app: "New transcript ready" toast (if app in foreground)

### Notification UX
- **One notification per sync cycle**, not per-dump
- Triggered when ≥1 dump is pending AND ≥6 hours since last dismissal
- Body: "N recordings awaiting sync · estimated upload: ~X MB · Wi-Fi only: ON/OFF"
- Actions: `[Confirm to Transcribe All]` / `[Later]`
- Background work: Android WorkManager-compatible periodic check

### Failure handling
- HTTP failure → mark dump `sync_status = 'failed'`, increment `sync_attempts`
- After 5 failures: dump stays `local_only` with notification "5 dumps couldn't sync, tap to retry"
- User can force-retry from Settings → Sync

---

## 11. First-launch onboarding

3 screens max before recording is possible:

### Screen 1: Welcome
```
┌────────────────────┐
│                    │
│   Tangent          │
│   "Go on a tangent."│
│                    │
│  [Get Started →]   │
│                    │
└────────────────────┘
```

### Screen 2: Microphone permission
```
┌────────────────────┐
│                    │
│  We need your      │
│  microphone.       │
│                    │
│  [Allow Microphone]│
│                    │
└────────────────────┘
```
On Android: triggers `RECORD_AUDIO` permission dialog.

### Screen 3: Server setup (skippable)
```
┌────────────────────┐
│                    │
│  Got a self-hosted │
│  server?           │
│                    │
│  [Skip]            │
│  [Add Server URL]  │
│                    │
└────────────────────┘
```
If Add: URL field + paste-token field → `POST /v1/setup` (one-time) OR paste existing token.

**Lands on:** home recording screen. Recording works immediately.

---

## 12. Recording screen

```
┌────────────────────────────────────┐
│              2:47                   │  ← time counter
│                                    │
│                                    │
│         ┌─────────────┐           │
│         │             │           │
│         │   ●  STOP  │           │  ← big button
│         │             │           │
│         └─────────────┘           │
│                                    │
│   ━━━━━━━━━━━━━━━━━━━━━━        │  ← level meter
│   ▌▌▌▌▌▌▓▓▓▓▓▒▒▒▒▒░░░            │
│                                    │
│   Today's dumps: 4                 │  ← context
└────────────────────────────────────┘
   (thin red border while recording)
```

See server spec §8 for the full design rationale.

---

## 13. Dumps list + search

```
┌────────────────────────────────────┐
│  Tangent                       [⚙]  │
│                                    │
│  ┌──────────────────────────────┐ │
│  │ 🔍 Search · 7 dumps          │ │
│  └──────────────────────────────┘ │
│                                    │
│  Filter: [All][Brain Dump][Meeting][⏳ Awaiting]│
│                                    │
│  ⚠ Awaiting sync (3) · tap to upload│
│                                    │
│  📝 "okay so the thing about..."  │
│     Brain Dump · 3:47 · 2m ago · ✓ │
│                                    │
│  📝 "yeah and then bob said..."    │
│     Meeting · 12:04 · 4:12 PM · ⏳ │
│                                    │
│  ── Yesterday ──────────────      │
│                                    │
│  📝 ...                            │
└────────────────────────────────────┘
```

See server spec §9 for full design rationale. Client-side search uses drift's FTS5; server-side search is out of scope (could be added in v2).

---

## 14. Settings screen

```
┌────────────────────────────────────┐
│  Settings                      [←] │
│                                    │
│  Server                             │
│  ──────                             │
│  Status: ● Connected                │
│  URL: http://homelab.lan:8000       │
│  [Edit]                             │
│                                    │
│  Recording                          │
│  ──────────                         │
│  Trigger: ◉ Tap  ○ Hold             │
│                                    │
│  Sync                               │
│  ────                               │
│  Wi-Fi only: ● On                   │
│  Auto-sync: ● On                    │
│  Last sync: 2 min ago               │
│                                    │
│  Data                               │
│  ────                               │
│  Local storage: 234 MB              │
│  [Export all]  [Delete synced]      │
│                                    │
│  About                              │
│  ─────                              │
│  Version: 1.0.0                     │
│  License: AGPL-3.0                  │
│  [View source]  [Privacy]           │
└────────────────────────────────────┘
```

---

## 15. Audio format

| Property | Value | Why |
|---|---|---|
| Codec | Opus | Best speech quality at low bitrate, fast to encode |
| Sample rate | 16 kHz | Whisper's native sample rate, no resampling needed server-side |
| Channels | Mono | Speech doesn't need stereo, halves file size |
| Bitrate | 32 kbps | Plenty for speech, ~240 KB/min |
| Container | Ogg Opus (`.opus`) | Native Opus container |

**File size example:** 10 min recording = ~2.4 MB. 60 min = ~14.4 MB.

---

## 16. Android permissions

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

No location permission (not needed). No external storage permission (audio stored in app-private dir).

---

## 17. Testing strategy

| Level | What | Where |
|---|---|---|
| Unit | Drift DAOs, sync engine, API client (with mocked HTTP) | `test/unit/` |
| Widget | Recording screen (tap behavior, level meter), dumps list (search/filter) | `test/widget/` |
| Integration | Record → save → upload → transcript visible | `test/integration/` (requires running server) |
| Manual | Real device microphone capture, background sync | Physical Android device |

**Coverage target:** ≥70% for unit + widget. Integration tests are best-effort.

---

## 18. Build + release

### Debug build
```bash
flutter pub get
flutter test
flutter run --debug  # connects to local server
```

### Release APK (signed with debug key for v1)
```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

For Play Store (v2+): need a proper signing key + Play Console setup. Out of scope for v1.

### Linux/Windows desktop
```bash
flutter build linux
flutter build windows
```
Both work today (Visual Studio 2026 already installed per `flutter doctor`).

---

## 19. v1 success criteria (client-side)

The client is "done" when ALL of the following are true:

1. **Solo install works** — User installs APK, grants mic permission, dumps first thought within 60 seconds, no server needed (dumps stay local)
2. **Server sync works** — User pastes server URL + token, sees dumps upload with `✓ Synced` badge, transcript appears within ~30 seconds (server uses large-v3)
3. **Search works** — User searches "deployment", finds a dump they made last week that mentioned it
4. **Background sync works** — User records on phone, closes app, reopens 5 min later, sees the transcript (sync notification posted, SSE delivered the result)
5. **Settings persist** — User changes Wi-Fi-only sync, closes app, reopens, setting is preserved
6. **APK installs and runs** on a fresh Android device without crash
7. **App passes AGPL compliance check** — no copyleft-incompatible dependencies

---

## 20. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Android SDK install fails mid-session | `STATUS.md` already documents this. Fall back to Windows desktop build (no Android SDK needed). |
| Server doesn't accept audio yet | Phase 2 server work: add `PUT /v1/dumps/{id}/audio` multipart endpoint. Without this, sync just uploads metadata; transcripts never come back. |
| Permission denied on Android | UI explains why we need it; if denied, app still records audio to local-only (no server sync). |
| Battery drain during long recording | Use foreground service on Android for recordings >1 min; show persistent notification |
| Server unreachable at recording time | App works fully offline; sync retries on next connectivity |

---

## 21. Sign-off

This spec is the canonical reference for Tangent v1 client (Phase 2). Any implementation that deviates from this document must update it first.

**Reviewers:** Jeff West (GyratingSeaCow) — primary author and decision-maker.
**Status:** Awaiting user review.
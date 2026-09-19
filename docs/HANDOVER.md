# Tangent — engineering handover

Written 2026-09-19. Everything below was verified against the live tree,
the running server, and both physical devices on the day it was written.
Where a number appears, it was read from a command, not remembered.

**Read these three files before touching anything:**

1. `docs/ENGINEERING-NOTES.md` — 98 KB of hard-won operational rules. Every
   entry was paid for with a real failure on real hardware. **This is the
   single most valuable document in the repo.**
2. `docs/design/audio-download.md` — design + current state of the
   in-progress feature.
3. This file.

---

## 1. What Tangent is

A voice recorder that transcribes locally-hosted, never in anyone's cloud.

- **client/** — Flutter + Kotlin Android app (`dev.tangent.tangent`).
- **server/** — FastAPI + faster-whisper in Docker, transcription and sync.

Two physical devices are in daily use with **real user audio**. This is not
a toy repo; destructive mistakes lose data that is not backed up anywhere
else.

### Owner

Jeff. Self-taught Linux power user, mobile PC repair technician. Preferences
that materially affect how you should work:

- **Verification over assurance.** "Run them now to prove they're working."
  Never report success you have not observed.
- **Fail loud, never silently fall back.** Surfacing an error beats
  auto-recovering into a wrong state.
- **Accuracy over speed** for transcription. When offered model sizes he
  picked the largest every time.
- Wants **direct answers and exact commands**, not theory.
- Treats silence on a decision question as a signal — if he does not answer,
  stop and wait rather than guessing.

---

## 2. Current state (verified 2026-09-19)

### Repository

```
C:/Users/Jeff/Documents/ADH2        branch: feature/blackout-ui
```

Last four commits:

```
473cb19  Repair transcription status on recordings that synced before the fix
c6924e9  Sync recordings between devices, not just notebooks
f0916cb  feat(notebook): lined page templates — schema v10, painter, picker, sync
7dbf066  feat(notebook): insert a new block below the one being edited
```

Everything through `473cb19` is committed, pushed, and **proven on hardware**.

### Uncommitted work — the tap-to-download feature

13 modified files + 3 new source files. This is **one coherent feature**,
finished except for device proof. See §6.

### Gates, run on the exact current tree

| Gate | Result |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **1303 passed**, exit 0 |
| Kotlin `testDebugUnitTest` | **99 tests, 0 failures** |
| Sabotage markers in source | **0** |

### Server

```
tangent-server | tangent-server:1.0.0 | Up 8 hours (healthy)
0.0.0.0:8765->8000/tcp
```

- Local: `http://localhost:8765`
- Tailscale: `http://100.88.126.107:8765`
- DB: `server/data/tangent.db` (1,077,248 bytes)
- Audio: `server/data/audio/` — **71 real recordings**
- Unauthenticated request → **401**. Bearer token auth.

### Devices

| Role | Serial | Model | Screen |
|---|---|---|---|
| Tablet | `R5GL65VR7JZ` | SM-X520 | 1440×2304 |
| Phone (Z Fold) | `RFGL82VCV6V` | SM-F971U1 | 1248×1972 |

Both currently run the `473cb19` build, client schema **v12**, holding **76**
and **75** recordings respectively.

### Toolchain

```
Flutter 3.27.1 stable (framework 17025dd882)
app version 1.0.0+1
adb      C:/Users/Jeff/AppData/Local/Android/Sdk/platform-tools/adb.exe
flutter  C:/Users/Jeff/AppData/Local/flutter/bin/flutter.bat
dart     C:/Users/Jeff/AppData/Local/flutter/bin/dart.bat
docker   /c/Program Files/Docker/Docker/resources/bin  (must be on PATH)
```

Host is **Windows 11**, shell is **git-bash/MSYS**, sources are **CRLF**.

---

## 3. Rules that will cost you if you ignore them

These are the ones that bite hardest. The full set is in
`docs/ENGINEERING-NOTES.md`.

### Never do these

- **Never `pm clear` or uninstall the app.** It destroys real recordings.
  A launcher was once cleared by accident; do not repeat it.
- **Never force-stop during a DB capture.**
- **Never push a verification copy of a DB back over user data.**
- **Never install while a recording is active.** Check first:
  ```bash
  adb -s <serial> shell dumpsys activity services dev.tangent.tangent | grep -ci RecordingService
  ```
  Must print `0`.
- **Never pipe a build or test through `tail`.** The exit code you see
  belongs to `tail` and the error text is gone. Do this instead:
  ```bash
  cmd > "$LOCALAPPDATA/Temp/x.log" 2>&1; echo "EXIT=$?"; grep -E "..." "$LOCALAPPDATA/Temp/x.log"
  ```
- **Never run two `flutter test` invocations at once.**
- **Never trust `BUILD SUCCESSFUL`** from Gradle as proof tests ran. Parse
  the XML in `client/build/app/test-results/testDebugUnitTest/` and check
  both the counts and the file mtimes.

### Windows/MSYS specifics

- Native tools (git, node, python, flutter) do **not** get MSYS path
  translation. Pass `C:/Users/...` forward-slash paths. `cd /c/Users/...`
  works because `cd` is a bash builtin; `git -C /c/Users/...` does not.
- Complex one-liners with backslashes break under MSYS quoting. Write a
  `.py` file and run it.
- Use `$LOCALAPPDATA/Temp` for scratch, not `/tmp`.

### Pulling a device database

Binary-safe transport is mandatory:

```bash
adb -s <serial> exec-out run-as dev.tangent.tangent cat app_flutter/tangent.sqlite > out.sqlite
```

`adb shell run-as ... cat` **corrupts it** — CRLF translation inflates the
file and sqlite reports "database disk image is malformed". The DB lives in
`app_flutter/`, not `databases/`. There is no `sqlite3` binary on the device
or the host; read the copy with Python's `sqlite3` module.

---

## 4. The verification standard used here

This is the project's defining convention and the reason its bug count is
low. Adopt it.

1. **A test that has never failed proves nothing.** Write the test first,
   watch it fail for the reason you expect, then fix.
2. **Sabotage load-bearing code** to prove the test actually guards it.
   Break the logic deliberately, confirm the specific test fails, restore,
   confirm green. Leave a `SABOTAGE` marker while doing it and grep to zero
   before finishing.
3. **Unit tests are not hardware acceptance.** A feature is not done until
   it has been exercised on a physical device with screenshots and
   persisted DB/file evidence.
4. **Integration seams are the dominant bug class in this repo.** Five of
   the six sync defects were code that passed its own unit tests while doing
   nothing useful at runtime. Always prove the caller reaches the callee.

---

## 5. Build, install, deploy

### APK

```bash
cd /c/Users/Jeff/Documents/ADH2/client
C:/Users/Jeff/AppData/Local/flutter/bin/flutter.bat build apk --debug \
  > "$LOCALAPPDATA/Temp/apk.log" 2>&1; echo "APK_EXIT=$?"
```

Run it as a background process; ~10 s with a warm Gradle cache, minutes cold.
Output: `client/build/app/outputs/flutter-apk/app-debug.apk`

### Install

```bash
# 1. confirm idle (must print 0)
adb -s R5GL65VR7JZ shell dumpsys activity services dev.tangent.tangent | grep -ci RecordingService
# 2. install over the top — NEVER uninstall first
adb -s R5GL65VR7JZ install -r "C:/Users/Jeff/Documents/ADH2/client/build/app/outputs/flutter-apk/app-debug.apk"
# 3. launch (this runs migrations)
adb -s R5GL65VR7JZ shell am start -n dev.tangent.tangent/.MainActivity
# 4. wait ~25 s, then confirm it did not crash on migration
adb -s R5GL65VR7JZ shell pidof dev.tangent.tangent
```

### Kotlin unit tests

```bash
cd /c/Users/Jeff/Documents/ADH2/client/android
"C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot/bin/java.exe" \
  -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain \
  :app:testDebugUnitTest --rerun-tasks
```

Then parse `client/build/app/test-results/testDebugUnitTest/*.xml` for real
counts.

### Server

```bash
export PATH="/c/Program Files/Docker/Docker/resources/bin:$PATH"
cd /c/Users/Jeff/Documents/ADH2/server
cp data/tangent.db "data/tangent.db.bak-$(date +%Y%m%d-%H%M%S)"   # always
DOCKER_BUILDKIT=0 docker compose build
docker compose up -d            # run as a BACKGROUND process
```

- The app is a **factory** (`create_app`) and has **no `/health` route** —
  poll `/openapi.json`.
- Polling `docker compose` mid-recreate shows the **old** container. Poll on
  **image ID**, not container age.
- **Never compose from a clone with a fixed `container_name`.**

---

## 6. The in-progress feature: tap-to-download audio

### Why it exists

Recordings now sync between devices, but **audio bytes never traverse the
sync feed** — only metadata and transcripts. A recording that originated on
the phone appears on the tablet as `remote_only` with no audio. This feature
adds an explicit, user-initiated fetch.

### Jeff's decisions (binding)

- Downloaded audio lands in **`Tangent Synced Audio`**, its own folder beside
  `Tangent Notebooks` and `Tangent Text Notes`. His reasoning was better than
  the options offered: it survives an app-data clear, re-adopts on import,
  and keeps synced copies visually distinct from local captures.
- **"Metadata always syncs; only audio fetch respects Wi-Fi-only."**

### Three constraints discovered by reading the code

These shaped the design. Do not "simplify" past them.

1. **`publishDocument` is text-only.** Kotlin does
   `content.toByteArray(Charsets.UTF_8)` and verifies readback against those
   bytes — audio would be corrupted and the readback check would fail anyway.
   Hence a new `publishBinaryDocument` path.
2. **`reserveCapture` cannot be reused.** It mints a fresh dump id for a new
   capture. A downloaded recording must keep the **server's** id, which
   already exists in `dumps`. So `AudioImporter` is not a usable template —
   it creates rows, whereas a download must attach audio to an existing one.
   (`storage_catalog.dart`, `reserveCapture`.)
3. **Playback requires a binding row.** Writing the file and setting
   `audio_path` alone produces a recording that **looks available and
   refuses to play**. Ordering is forced by `bindRecording`
   (`local_db.dart:954`): at **line 967** it re-reads the dump and faults
   with `ProblemCode.conflict` / `'Original audio identity differs'` unless
   `row.audioPath` **already equals** the binding's locator. So the sequence
   must be **publish → attach → bind**, and the service does exactly that.

### What is built

| Layer | File |
|---|---|
| Contract | `storage_contract.dart` — `syncedAudioSubdirectoryName`, `publishBinaryDocument` |
| Dart backends | `filesystem_storage_backend.dart`, `saf_storage_backend.dart` |
| Kotlin | `DocumentPublication.kt` — shared atomic write, binary dispatch |
| Native wiring | `StorageChannel.kt`, `AndroidDocumentsPort.kt`, allow-list |
| DB | `local_db.dart` — `clearDownloadedAudio(id)` reverts a failed download |
| Service | `synced_audio_download.dart` — fetch, gate, publish, attach, bind |
| UI | `item_action_sheet.dart` (`ItemAction.download`), `dumps_providers.dart` (provider + `dumpNeedsAudioDownload`), `dumps_list_screen.dart` (menu + handler) |

Design details:

- The action appears **only** where `audioOnServer == true && remoteOnly == true`.
- It lives on the per-row **⋮ menu**, never on long-press — long-press is the
  bulk-delete entry point and 28 tests encode that contract.
- With no storage folder selected it shows **disabled with a reason**, not
  hidden. A control that vanishes reads as a bug.
- The Wi-Fi/offline gate runs **before** the fetch, so a refusal costs no
  data, and its wording goes to the snackbar verbatim rather than being
  flattened to "download failed".
- `.opus` declares MIME `audio/ogg` (an Opus file is an Ogg container), and
  `tempExtension` maps it to `.ogg` — this avoids a historical `.wav.oga`
  corruption bug.
- A zero-byte response is rejected rather than published.
- Any failure after attach calls `clearDownloadedAudio` to put the row back
  to remote-only, so a partial failure never leaves an unplayable row.

### Tests

- `synced_audio_download_test.dart` — **11**, including byte-exactness,
  playability binding, Wi-Fi refusal, offline refusal, idempotent re-download.
- `dumps_list_download_action_test.dart` — **5**, proving the action reaches
  the screen and that long-press still means multi-select.
- Sabotages proven: skipping the bind, truncating the bytes, and dropping the
  `remoteOnly` half of the predicate each failed the right test.

### What remains — the only work left

1. Re-run the Kotlin suite (native code changed; it was 99/99 before the UI
   work).
2. Build the APK.
3. Install on both devices.
4. **Device proof, not yet done:**
   - Tap download on a `remote_only` recording.
   - Verify the file appears in `Tangent Synced Audio`.
   - Byte-compare against `server/data/audio/<id>.opus`.
   - **Play it** — this is what proves the binding, and nothing else does.
   - Toggle Wi-Fi-only on mobile data and confirm the refusal wording.
   - Confirm the row flips from "on server" to locally available.
5. Commit. Nothing in this feature is committed yet.

---

## 7. Architecture facts worth knowing up front

### Sync

- Wire contract: push `{entity_type, entity_id, op: "upsert"|"delete",
  payload, updated_at}`; pull returns `head_seq` plus changes.
- **Audio bytes never traverse the feed.** Metadata and transcripts only.
- Recordings do **not** fork on conflict; notebooks do.
- New captures are `syncDirty: true` **except** `mode == 'meeting'`, which
  stays deliberately device-local.
- `sync_status` is a **legacy column the current engine ignores** — do not
  reason from it.
- `/v1/sync/push` republishes **server truth**, re-read from storage, not the
  client's payload. An earlier version echoed the client and broadcast an
  audio-less device's omission to every peer.

### Client database

- Schema is at **v12**, Drift-managed, at `app_flutter/tangent.sqlite`.
- v11 added four **nullable** dump sync columns (`sync_dirty`, `synced_seq`,
  `remote_only`, `audio_on_server`). Nullable was deliberate: non-nullable
  would have forced them into `DumpRow`'s constructor and broken 141 call
  sites.
- v12 is a **data-only repair** migration.

### Migration doctrine (learned the hard way)

- Fixing an apply-side bug does **not** heal rows already written under it —
  their `synced_seq` is current, so the feed never replays them. Every
  apply-path fix needs a paired one-time repair.
- Repairs ship as **migrations**, never as manual scripts against live
  device DBs.
- A repair must **not** touch `updated_at` or `sync_dirty`, or it spams the
  change feed with a device-local correction.
- **Guard every repair with `PRAGMA table_info`.** Migrations run in
  sequence and a later step can reach a column that does not exist yet on an
  old install. This exact mistake would have bricked launch for the oldest
  installs; 13 pre-existing tests caught it.
- **SQLite `TRIM()` strips spaces only** — not newlines or tabs. Use
  `TRIM(x, ' '||char(9)||char(10)||char(13))`.
- Verification pattern: rehearse against **copies of the real device DBs**,
  then require the on-device result to match the rehearsal exactly.

### The six sync defects (context for why the code looks like it does)

1. `dumps.py` create/patch/delete/upload never called `record_change`.
2. `upload_audio` never set `audio_kept=1` — 71 files on disk, 0 rows
   claiming audio.
3. `job_queue.py` wrote transcripts but published nothing.
4. `_apply_dump` hardcoded `audio_kept = 0` and dropped `meeting_notes`.
5. `/v1/sync/push` republished the client payload instead of server truth.
6. `applyRemoteDump` never set `transcription_status`, so 37 recordings
   holding real transcript text displayed "Not transcribed".

Five of six passed their unit tests. That is why §4 exists.

---

## 8. Known issues and gotchas

- **`server_transcription_service_test.dart` is timing-flaky under full-suite
  load.** It passes in isolation. Before blaming a change, run that file
  alone and re-run the suite. Seen once this session; the clean re-run gave
  1303.
- **`item_action_sheet_test.dart` needs a tall test surface.** A modal bottom
  sheet is capped at 9/16 screen height, and `scrollUntilVisible` **dismisses
  the sheet** (a drag is its dismiss gesture), failing with
  `Bad state: No element`. Adding an 8th action tripped this. Fixed by
  sizing the surface, not weakening the assertion.
- **Adding an `ItemAction` variant breaks unrelated screens.** Dart switches
  are exhaustive; `notebook_list_screen.dart` failed to compile. After adding
  an enum value, grep every screen for it.
- **`ConnectivityStatus` has `isOnline`, not `online`.** Confirm member names
  before use; do not guess.
- **`Value` for Drift nullable columns needs
  `import 'package:drift/drift.dart' show Value;`** in tests.
- The dumps list has a pending redesign (§3 of `docs/next-iteration.md`):
  collapse the mode and transcript filter chip rows into one dropdown bar.
  **It touches `dumps_list_screen.dart`, the same file as the download UI** —
  land the download feature first, or expect conflicts. Four widget test
  files reference the chip keys.

---

## 9. Immediate next commands

The tree is clean and fully green right now. To resume:

```bash
# 1. confirm the handover state for yourself
cd /c/Users/Jeff/Documents/ADH2/client
C:/Users/Jeff/AppData/Local/flutter/bin/flutter.bat analyze          # No issues found
C:/Users/Jeff/AppData/Local/flutter/bin/flutter.bat test             # 1303 passed

# 2. Kotlin, since native code changed
cd android && "C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot/bin/java.exe" \
  -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain \
  :app:testDebugUnitTest --rerun-tasks

# 3. build, install, and prove it on hardware (§6.5)
```

Then commit the download feature as one unit.

---

## 10. Honest status

The download feature is **code-complete and fully green in tests, with zero
device proof**. By this project's own standard that means **not done**. Do
not describe it to Jeff as working until you have downloaded a recording on
a real device and played it back.

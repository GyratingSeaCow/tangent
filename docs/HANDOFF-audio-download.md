# HANDOFF — Tangent tap-to-download audio (mid-task)

Written 2026-09-19 by the previous agent window, which ran out of context.
Repo: `C:/Users/Jeff/Documents/ADH2`, branch `feature/blackout-ui`.

**Read this whole file before touching anything.** The work is half-done in a
specific, recoverable way, and the parts that are done were expensive to get
right.

---

## 0. FIRST ACTIONS (do these before anything else)

1. `skill_view(name='tangent-app-development')` — mandatory. It carries the
   project's verification standard and ~80 pitfalls that have each cost a
   device round trip. This handoff does NOT repeat most of them.
2. Read `docs/design/audio-download.md` in the repo — the design notes with
   file:line references for every claim below.
3. Verify the tree state matches section 2. If it does not, STOP and tell
   Jeff rather than guessing what changed.

---

## 1. WHAT JEFF ASKED FOR

Verbatim, the standing instruction for this whole arc:

> "I want you to build straight through until you have it completely setup,
> tested, and installed."

And the decision that shaped the current task, asked and answered 2026-09-19:

> Q: Where should downloaded audio land?
> A: "downloaded audio should land in it's own dedicated folder saved
>    similarly to how Tangent Notebooks/Tangent Text Notes lives"

Folder name, confirmed by Jeff: **`Tangent Synced Audio`**.

Do not re-litigate either decision. The folder name in particular is
permanent — renaming later strands every file already published under the
old name.

---

## 2. EXACT TREE STATE (verified, not remembered)

Branch `feature/blackout-ui`. Last commits:

```
473cb19 Repair transcription status on recordings that synced before the fix
c6924e9 Sync recordings between devices, not just notebooks
f0916cb feat(notebook): lined page templates — schema v10, painter, picker, sync
```

`473cb19` and `c6924e9` are **pushed and device-verified**. Do not revisit.

### Uncommitted (this is the in-flight work)

```
 M client/android/.../storage/AndroidDocumentsPort.kt        (+1/-1)
 M client/android/.../storage/DocumentPublication.kt         (+40)
 M client/android/.../storage/StorageChannel.kt              (+3/-1)
 M client/android/.../test/.../StorageMethodRouterTest.kt    (+5/-1)
 M client/lib/data/local_db.dart                             (+16)
 M client/lib/data/storage/filesystem_storage_backend.dart   (+49)
 M client/lib/data/storage/saf_storage_backend.dart          (+43)
 M client/lib/data/storage/storage_contract.dart             (+33)
?? client/lib/services/synced_audio_download.dart            (new)
?? client/test/unit/services/synced_audio_download_test.dart (new, 7 tests)
?? docs/design/audio-download.md                             (new)
```

**Nothing here is committed.** All of it is green (section 4). It is safe to
commit once the UI lands and device proof exists — but see section 7 for the
rule about committing device-unverified work.

### Environment

- Devices attached: tablet `<tab-s10fe-serial>` (SM-X520), Fold `<fold-serial>`
  (SM-F971U1). Both currently run the app built at `473cb19`, schema v12.
- Server: container `tangent-server`, `Up (healthy)`, image
  `tangent-server:1.0.0`. Port 8765, Tailscale `<server-tailscale-ip>:8765`.
  **The running image does NOT contain the uncommitted work** — but none of
  the uncommitted work is server-side, so no rebuild is needed.
- Library state on device: tablet 76 recordings, Fold 75. Real user data.

---

## 3. WHAT IS BUILT (all green)

The goal: a synced recording arrives carrying metadata + transcript but no
audio (`remote_only=1`, empty `audio_path`, `audio_on_server=1`). Tapping
should fetch the bytes and make the recording PLAY.

| Layer | Status | File |
|---|---|---|
| Server route | DONE (pre-existing) | `GET /v1/dumps/{id}/audio` |
| Client fetch | DONE (pre-existing) | `transcription_client.dart:466` `downloadAudio` |
| Folder constant | DONE | `storage_contract.dart` `syncedAudioSubdirectoryName` |
| Binary port method | DONE | `storage_contract.dart` `publishBinaryDocument` |
| Filesystem backend | DONE | `filesystem_storage_backend.dart` |
| SAF backend | DONE | `saf_storage_backend.dart` |
| Kotlin binary publish | DONE | `DocumentPublication.publishBinary` + shared `write()` |
| Native allow-list | DONE | `AndroidDocumentsPort.kt`, `StorageChannel.kt` (×2 sites) |
| Router gate test | DONE | `StorageMethodRouterTest.kt` |
| Revert helper | DONE | `local_db.dart` `clearDownloadedAudio` |
| Download service | DONE | `services/synced_audio_download.dart` |
| **UI button** | **NOT BUILT** | — |
| **Wi-Fi-only gate** | **NOT WIRED** | — |
| **Provider wiring** | **NOT BUILT** | — |
| **Device proof** | **NONE** | — |

---

## 4. VERIFICATION ALREADY DONE (do not redo)

- `flutter test` → **1294 passed** (was 1287 before this work; +7 new).
- `flutter analyze` → **No issues found**.
- Kotlin `:app:testDebugUnitTest --rerun-tasks` → **BUILD SUCCESSFUL**, and
  counts parsed from `client/build/app/test-results/testDebugUnitTest/*.xml`
  = **99 tests, 0 failures, 0 errors**, files 5s old. (Never trust
  `BUILD SUCCESSFUL` alone — an up-to-date task prints it happily.)
- Sabotage ×2, both proven load-bearing then restored, `markers=0`:
  - Skip `bindRecording` → the playability test fails.
  - Truncate the published bytes → the byte-exactness test fails.

### One flake you will likely hit

`test/unit/services/server_transcription_service_test.dart` failed once in a
full run ("ordinary recoverable local exit was not reconciled"), then passed
alone (109/109) and the next full run was clean at 1294. This file is
timing-sensitive under load. If you see it fail, re-run it alone before
believing it. **Never run two `flutter test` invocations concurrently.**

---

## 5. THE THREE CONSTRAINTS THAT SHAPED THE DESIGN

These were each discovered by reading code and cost real time. Do not
re-derive them, and do not "simplify" around them.

### 5.1 `publishDocument` is TEXT-ONLY — this is why a new port method exists

`DocumentPublication.kt` did `content.toByteArray(Charsets.UTF_8)` and
verified readback with `contentEquals` on those UTF-8 bytes. Audio cannot
travel through it: the encoding corrupts the bytes and the readback check
would fail anyway. Base64 was rejected — the file must be a playable `.opus`
in the user's folder, not an encoded blob.

The new `publishBinary` shares a private `write(...)` with the text path, so
the atomic **temp → verify → park → rename → delete** sequence can never
drift between them. Keep it that way.

### 5.2 `reserveCapture` CANNOT be reused

`storage_catalog.dart:458` mints a fresh id and, at line 501, rejects any id
already present in `dumps` / `recording_bindings` / `local_deletion_tickets`
/ `capture_reservations`. A downloaded recording keeps the **server's** dump
id, which is already in `dumps`.

Consequence: the `AudioImporter` template (`services/audio_import.dart`) does
NOT transfer. It creates a NEW dump; download must ATTACH audio to an
existing synced row. If you find yourself reaching for `reserveCapture`,
you have taken a wrong turn.

### 5.3 Playback requires a binding row, and the order is forced

- `resolveRecording` (`storage_catalog.dart:439`) faults
  `ProblemCode.conflict` / 'Original audio identity differs' (local_db.dart:967) when
  `recording_bindings` has no row. `dump_detail_screen.dart:136` plays via
  `access.openPlayback(binding.key, raw)`.
- `bindRecording` verifies the dump's `audio_path` **already equals** the
  binding's locator (guard at `local_db.dart:951`, fault raised at `:970`),
  else faults 'Original audio identity differs'.

So the sequence is **publish → attach → bind**, in that order. Writing the
file and setting `audio_path` without binding produces a recording that
looks available and refuses to open — the exact "adopted, not merely
written" trap. Sabotage confirmed the guard catches it.

---

## 6. WHAT TO DO NEXT (in order)

### Step 1 — Provider wiring

`SyncedAudioDownloader` currently has **zero call sites**. Per the skill,
"an implemented, unit-tested method with zero callers is the default outcome
of parallel work and passes every gate while doing nothing at runtime."
Treat the feature as not existing until a provider builds it and a widget
calls it.

It needs: `LocalDb`, a `StorageBackend`, the selected `StorageLocation`, and
a `SyncedAudioFetch` (wire to `TranscriptionClient.downloadAudio`).

Look at how `notebook_persistence.dart` obtains its location
(`_location()`) and mirror that — it faults on an unavailable folder rather
than silently skipping publication, which is the right behaviour here too.

### Step 2 — Wi-Fi-only gate

`settings_store.dart` has `wifiOnlySync` (key `wifi_only_sync`, defaults
true). Jeff's rule, verbatim and binding:

> "Metadata always syncs; only audio fetch respects Wi-Fi-only"

So this gate belongs **only** on the audio fetch, never on the sync engine.
Check connectivity BEFORE the network call. Note the skill's warning: a fake
returning a bare `true` for `ConnectivityService.currentStatus()` is wrong —
it returns a `ConnectivityStatus` enum, and a `noSuchMethod` fake that
answers `true` makes the engine read as offline while every test passes.

### Step 3 — The UI affordance

Site: `client/lib/screens/dump/dumps_list_screen.dart` (898 lines). There is
already a per-row overflow menu (three-dot) — that is the correct entry
point.

**Hard rule from the skill, learned the expensive way:** give the new action
its OWN entry point. Do not overload the row tap (it means "open") and do
not overload long-press (there is an existing safety contract — a test is
literally titled "long press selects; row and circular control never
navigate"). Four new tests passing while twenty-eight old ones fail is the
suite out-voting you.

Show the affordance when `audioOnServer == true && remoteOnly == true`.
When Wi-Fi-only blocks it, **disable with a stated reason rather than
hiding** — a control that vanishes reads as a bug; a greyed row carrying
the reason explains the app.

Give the download a visible busy state. The skill is explicit: while
work-in-progress renders as idle, a hang, a rejected fetch and a dead
control all look identical, and each theory costs a device round trip.

Widget-test notes that will bite otherwise:
- A `StreamProvider` delivers its first value a frame AFTER mount — pump
  twice before asserting, or the list renders empty and reads as "the
  feature does not render".
- Dropdown/menu items do not exist in the tree until the menu is opened.
- Add `Key`s to anything new so later restyling is cheap.

### Step 4 — Device proof (MANDATORY — this is the actual deliverable)

Unit tests are NOT hardware acceptance here. Required evidence:

1. Check no active capture before installing:
   `adb -s <serial> shell dumpsys activity services dev.tangent.tangent | grep -ci RecordingService` → must be 0.
   Installing force-stops the app and would interrupt a live recording of
   Jeff's.
2. Build + install both devices.
3. On the **Fold** (`<fold-serial>`), find a row with `audio_on_server=1` and
   `remote_only=1`, tap download.
4. Pull the DB and confirm `remote_only=0`, `audio_path` non-empty,
   `audio_size_bytes` matches, and a `recording_bindings` row exists.
5. **Byte-compare** the on-device file against `server/data/audio/<id>.opus`.
6. **PLAY it in the app.** A metadata row is not audio-transfer evidence.
7. Confirm the file is in `Tangent Synced Audio`, not the folder root:
   `adb -s <serial> shell ls "/sdcard/Documents/Tangent/Tangent Synced Audio"`
8. Screenshot the receiving device.
9. Confirm notebooks still sync (non-regression).

### Step 5 — Commit

Only after step 4 passes. The skill's rule: do NOT commit a feature whose
device verification failed, however green the gates are.

---

## 7. RULES THAT APPLY TO EVERY STEP

**Verification**
- Jeff wants proof, not claims. Quote real output from real runs.
- `cmd > log 2>&1; echo "EXIT=$?"` then grep the log. **Never** pipe builds
  or tests through `tail` — the exit code you see belongs to `tail`.
- Never set a terminal timeout above 600s (it silently becomes a background
  job and its notification can report a stale run).
- Any test encoding a fix must be sabotage-proven: mutate, watch it fail,
  restore, watch it pass, and report both. Verify the mutation LANDED with
  a marker grep — a no-op patch reads as a weak test.

**Editing**
- Sources are **CRLF**. Use the `patch` tool; an LF search string from
  Python/sed silently no-ops and leaves the tree mutated.
- Anchor inserts on the END of a preceding member (through its closing
  brace), never on the `class X {` line — these classes open with named-
  parameter constructors and an insert there lands between parameters.
- Check each patch's success flag before the dependent step.

**Device safety**
- NEVER uninstall, `pm clear`, or delete anything you did not create. A
  `pm clear` on the launcher once wiped Jeff's entire home screen.
- Check the foreground app before any synthetic input — Jeff uses these
  devices while you work.
- Pull DBs with `adb exec-out run-as dev.tangent.tangent cat
  app_flutter/tangent.sqlite > out.sqlite`. Plain `adb shell cat` corrupts
  binary.
- Read tap coordinates fresh from a screenshot or `uiautomator dump`; stale
  coordinates silently hit the neighbouring control.
- Leave the device in a WORKING configuration before ending a turn.

**Honesty**
- Retract a wrong claim in the same message as the disproof. This session
  already had to retract "your devices have never uploaded anything" — it
  was wrong, and built on a legacy `sync_status` column that nothing writes.
- State which of "works" / "partially works" / "does not work" applies to
  each item, with the evidence for each.
- End a report by saying who does what next, and recommend one option.

---

## 8. COMMANDS AND PATHS

```
ADB       C:/Users/Jeff/AppData/Local/Android/Sdk/platform-tools/adb.exe
Flutter   C:/Users/Jeff/AppData/Local/flutter/bin/flutter.bat
Dart      C:/Users/Jeff/AppData/Local/flutter/bin/dart.bat
JDK       C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot
APK       client/build/app/outputs/flutter-apk/app-debug.apk
Package   dev.tangent.tangent/.MainActivity
Devices   <tab-s10fe-serial> (tablet), <fold-serial> (Fold)
```

Kotlin tests (the bash `gradlew` wrapper fails under MSYS):

```bash
cd /c/Users/Jeff/Documents/ADH2/client/android && \
"C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot/bin/java.exe" \
  -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain \
  :app:testDebugUnitTest --rerun-tasks
```

Then parse counts from `client/build/app/test-results/testDebugUnitTest/*.xml`
(attributes `tests`/`failures`/`errors`) and check the file mtimes are from
this run.

Docker (only if server work becomes necessary — it should not):

```bash
export PATH="/c/Program Files/Docker/Docker/resources/bin:$PATH"
export DOCKER_BUILDKIT=0
# `docker compose up -d` must run as a BACKGROUND process; the terminal tool
# refuses it in the foreground. Poll on the IMAGE ID, not `docker ps` text —
# a recreate shows the OLD container as "Up N hours" mid-swap.
```

Scratch dir with helper scripts from this session:
`$LOCALAPPDATA/Temp/tangent-verify/` — `inspect.py`, `snap.py`, `scope.py`,
`rehearse.py`, `check_overlap.py`, plus `before/` and `after/` DB copies and
numbered screenshots (`60-*.png` … `71-fold-repaired.png`).

---

## 9. WHAT ELSE IS ON THE BACKLOG (not started, do not start without asking)

`docs/next-iteration.md` §3 — collapse the Dumps page Mode and Transcript
chip rows into a single top bar with dropdown menus. Jeff asked for this
mid-session; it is spec'd with real code references. Target is `_FilterRow`
in `dumps_list_screen.dart`; the chip keys `mode-filter-*` /
`transcript-filter-*` are referenced by **four** test files that will need
updating.

**Note the collision:** that work and the download-UI work touch the SAME
file (`dumps_list_screen.dart`). Finish and commit the download UI before
starting §3, or expect to resolve conflicts in a 898-line screen.

---

## 10. ONE-PARAGRAPH SUMMARY IF YOU READ NOTHING ELSE

Recording sync between Jeff's two devices is DONE, committed (`c6924e9`,
`473cb19`), pushed, and proven on hardware. The current task is tap-to-
download audio: the entire storage/service layer is built and green
(1294 Dart tests, 99 Kotlin tests, analyze clean, two sabotages proven) but
**uncommitted**, and it has **no UI, no provider wiring, and zero device
proof**. Downloaded audio must publish into `Tangent Synced Audio` via the
new `publishBinaryDocument` port method, then attach, then bind — in that
order — because playback resolves through `recording_bindings` and
`bindRecording` checks `audio_path` first. Next action: wire a provider,
add a download item to the existing per-row overflow menu in
`dumps_list_screen.dart` (its own entry point, never the row tap), gate the
fetch on Wi-Fi-only, then prove it on the Fold with a byte comparison
against the server and real playback before committing.

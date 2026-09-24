# Tangent handoff — 2026-09-20 evening (post-v1.5.1, post reinstall-test)

Self-contained brief for the next conversation. Read top to bottom before acting.

## What Tangent is

Jeff's main project: self-hosted, offline-first voice brain-dump app for ADHD brains.
- Repo: `C:\Users\Jeff\Documents\ADH2` → github.com/GyratingSeaCow/tangent (AGPL-3.0)
- `client/` = Flutter (Android; Linux/Windows scaffolds exist), `server/` = FastAPI + Whisper large-v3 in Docker
- When Jeff says "the app" he means Tangent. Load the `tangent-app-development` skill FIRST — it has the standing UI rules, test traps, deploy pipeline, and references (toolbar-import-export, list-screens-and-folders, notebook-canvas-editing, sync-server-and-pairing are the load-bearing ones).

## Current state (all verified, nothing in flight)

- **main = `e4d81d0` "Release v1.5.1"**, pushed, CI green through the previous commit (v1.5.1 CI was in_progress at last check — verify with `gh run list --branch main --limit 1`).
- **Releases:** v1.5.1 (Latest, `tangent-v1.5.1.apk`, 64.6MB, versionCode 6) and v1.5.0 earlier the same day. Both signature-verified pre-upload (CN=Tangent). Tags: v1.2, v1.3.0, v1.4.0, v1.5.0, v1.5.1.
- **Tests:** client 1424/1424, `flutter analyze` clean, server 180/180. No known defects.
- **Working tree:** clean except untracked `server/.venv-test/` (ignore it). STATUS.md is deliberately gitignored/local.

## What shipped today (2026-09-20), newest first

1. **Eraser/repaint performance** (`8fd6e60`) — cached bounding-box precheck (Expando on immutable stroke objects), allocation-free hit-test inner loop, fountain strokes batch into ONE Path/drawPath. Painter unit tests now pin the single-path contract via geometric probes.
2. **Unified notebook toolbar** (`a060b04`) — draw/eraser/nib/lasso/undo/redo/pen-size on one always-visible row under the title; tools DISABLED (grayed) outside draw mode, never hidden; PenSizeControl.onChanged is now nullable (true disabled state).
3. **v1.5.0 release** (`f31508d`) — dumps-into-folders (shared folder system + shared `folder_header_actions.dart`), folder rename/delete via header long-press, notebook PDF export (⋮ menu → renders via NotebookInkPainter → system share sheet, `lib/services/notebook_pdf_exporter.dart`), dump import shape chooser (Audio bubble vs Text — transcript into an editable text block, honest "(no transcript)" fallback), content-aware insert (new items land below lowest existing block AND ink, `_contentBottom()` in notebook_editor_screen.dart).
4. Earlier same arc: notebook multi-select unification (`5eee414`), folder header rename/delete (`f2fee3f`), v1.4.0 release (`caa89a2`), Linux handoff doc (`docs/HANDOFF-linux-desktop.md`).

## THE BIG STATE CHANGE: both devices are now on the RELEASE track

Jeff ran the full new-user test: backed up, uninstalled Tangent from both devices, reinstalled from the GitHub release page, paired via 6-digit code, sync restored all data (verified server-side: 2 pairings claimed 23:10–23:11Z, both devices pulled from since_seq=0, 27 notebooks / 87 dumps / 7 folders back).

Consequences for the next conversation:
- **NO MORE DEBUG DEPLOYS via `flutter build apk --debug` + `adb install -r`.** Both devices run release-signed builds. A debug APK will be REFUSED (signature mismatch); forcing it costs a data wipe.
- To put a test build on a device: `flutter build apk --release` (release key is configured in the repo's signing setup) then `adb install -r` the release APK. Or cut a GitHub pre-release.
- `run-as dev.tangent.tangent` on-device DB inspection NO LONGER WORKS (release builds aren't debuggable). Verify via sync/server DB instead: `C:/Users/Jeff/Documents/ADH2/server/data/tangent.db` (sqlite3 via python).
- Update path for Jeff's devices = real-user path: download APK from Releases, install over the top. SAF folder re-grant needed after every install.
- Devices: tablet `R5GL65VR7JZ` (USB), Fold via tailnet `adb connect 100.92.184.58:5555` (drops offline sometimes — retry connect, then ping, then defer to Jeff). Check RecordingService count = 0 before any install.

## Backup (keep until Jeff says delete)

`C:\Users\Jeff\Documents\ADH2-backups\pre-reinstall-20260920\` (219MB, has RESTORE.md):
per-device app_flutter.tar (DBs) + prefs-files.tar (tokens) + Documents-Tangent/ (audio), plus server-data/ (integrity-checked sqlite .backup + audio). Sync has proven this redundant but it stays as belt-and-braces.

## Server facts

- Container `tangent-server` (image tag still 1.3.0 — cosmetic; code is current, no server changes since v1.4.0), host port 8765, healthy, data in `server/data/` (bind mount).
- Liveness: `curl http://localhost:8765/v1/server/info/public` (NOT /health).
- Pairing code readout (Jeff's PowerShell — he uses PS, give him Select-String not grep):
  `docker compose -f C:\Users\Jeff\Documents\ADH2\server\docker-compose.yml logs tangent-server --since 5m | Select-String code_issued`
- Server DB now has 6 device_tokens (2 new from the reinstall + old ones incl. `jeff-cachyos` and a stale e2e bench token). Old wiped-device tokens are harmless; revocable via `DELETE /v1/devices/{id}/token` if Jeff wants cleanup.

## OPEN WORK (priority order)

1. **README restructure — promised to Jeff, not yet done.** Finding from the reinstall test: he landed in the server-setup wall of docker/curl when all he needed was "install APK → pair". Add an "Already have a server? 3 steps" fast path at the TOP of Quick start, server setup below for first-timers. Second finding: pairing needs a second machine mid-flow to read the code from docker logs — call that out prominently in the pairing section (and consider a future feature: server page showing active codes).
2. **Dumps folder collapse-state is session-only** (notebooks persist theirs in SharedPreferences). Flagged to Jeff; fix if he asks.
3. **Possible future perf lever** (only if Jeff still feels lag with several dense screens of ink): cache built Path objects per stroke, then rasterize settled ink to a picture layer.
4. **Linux desktop companion** — CachyOS Hermes agent has `docs/HANDOFF-linux-desktop.md`, branch `feature/linux-desktop`. Its update = `git pull` in its clone. Known edge added since the doc: share_plus has no real Linux share sheet → PDF export on desktop needs a save dialog instead.
5. **Virgin-server setup test** — offered, Jeff hasn't asked. Throwaway dir + different port, never against his live data.
6. `feature/blackout-ui` branch: fully merged, 0 ahead, safe to delete, never done.

## Working rules that keep biting (from today)

- Prove tests RED before implementing; sabotage load-bearing tests before committing (restore via targeted patch). A surviving sabotage = coverage gap → add the missing test first. Happened TWICE today (dump rule 6, fountain painter pinned the old rendering).
- Widget tests must NEVER touch a real drift DB (`!timersPending` hang) — use `test/support/fake_folders_db.dart`; the dumps transcription-indicator fixture needed a `foldersProvider` override when the screen started watching folders (provider-watch test-ripple trap — documented in skill).
- flutter test full suite: ALWAYS background (`terminal background:true notify:true` + read `$LOCALAPPDATA/Temp/full_suite_runN.txt`); foreground caps at 420s and the suite + compile can exceed it. Never two flutter tests concurrently.
- CRLF: python edits must use `nl = '\r\n' if '\r\n' in raw else '\n'`. Heredocs with Dart code mangle in git-bash — write a .py script to `$LOCALAPPDATA/Temp` and run it.
- adb/native tools need `C:/...` paths, not `/c/...` (MSYS conversion is off).
- Release ritual: bump pubspec version+code, CHANGELOG section, README badges (version AND test count — they go stale), AGENTS.md Status (goes stale too), build release APK, `apksigner verify --print-certs` (build-tools 34.0.0, NOT 35 — doesn't exist) + `aapt dump badging` BEFORE upload, commit "Release vX.Y.Z", `gh release create vX.Y.Z <apk> --latest`. `gh release view` has no `isLatest` field — use `gh release list`.
- Jeff wants: fail-loud (no silent no-op controls — disabled beats dead), accuracy over speed, hands-on verification requests batched at the END, concise action-first answers.

## Session recovery

Full history: session_search(session_id='20260919_121405_16fff0'). Backup manifest: `ADH2-backups/pre-reinstall-20260920/RESTORE.md`.

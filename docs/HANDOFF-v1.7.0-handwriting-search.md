# Tangent v1.7.0 — Handwriting Search — Session Handoff

**Generated:** 2026-09-22 (session `20260920_192623_b2214e`)
**Repo:** `C:\Users\Jeff\Documents\ADH2` (GitHub `GyratingSeaCow/tangent`)
**Branch:** `main` — clean tree, **12 commits ahead of `origin/main`, NOTHING PUSHED**
**Last commit:** `6e83ba3 fix(android): R8 keep rules for notifications; init survives plugin failure (E2E)`

---

## 1. What this arc is

Handwriting search for Tangent notebooks, via **server-side OCR**. Ships as **v1.7.0**.

**Pipeline:** notebook ink syncs to server → geometric stroke segmentation into lines →
clean line rendering (PNG) → TrOCR-base recognition → word-level index rows (text + bbox +
contributing stroke IDs) → index syncs back down to every device → **search is local/offline
everywhere**, Ctrl+F-style highlighting repaints the matched strokes.

### Binding decisions (yours, do not relitigate)
| Decision | Detail |
|---|---|
| Server-side, not on-device | ML Kit is Android/iOS-only; **Linux desktop must search** ("changing paths to the other way instead") |
| Model | **TrOCR-base everywhere.** Bake-off on your real cursive: base beat large **3/24 vs 6/24** word errors. GPU = faster backfill, *same model* |
| CPU-first | CPU install path is fully supported ("some people will not be able to run this GPUs") — RTX is acceleration, not a requirement |
| Off by default | Settings toggle, install wizard, exact prompt: **"Are you sure you want to install the RTX 50 Series OCR ability?"** → progress notification → completion notification |
| Toggle OFF | Feature *fully* off: no model, no index, no search UI |
| Search UX | Search icon in top toolbar on **both** Notebooks home and in-notebook. Home = match count + snippet, tap opens at top result. In-notebook = ctrl+F highlight + next/prev + n/m |

### Key docs in-repo
- `docs/design/2026-09-21-handwriting-search-ocr.md` — approved spec
- `docs/design/2026-09-21-handwriting-search-ocr-plan.md` — 8-task plan
- `docs/design/2026-09-21-ocr-bakeoff-results.md` — bake-off evidence
- `.superpowers/sdd/2026-09-21-handwriting-search-ocr-plan/` — **gitignored**: ledger (`progress.md`), per-task briefs/reports, `e2e-fix-report.md`, review diffs

---

## 2. Status: build COMPLETE, shipping IN PROGRESS

**Tasks 0–6 complete.** Every task went through: implementer → task review → fix rounds →
scoped re-review. Then a **final whole-branch review**, one fix wave, re-review clean.
Branch merged to main (`44e327d`, +8,178 lines / 50 files).

**Task 7 (ship) is where we are now.** Steps 1–3 partially done; E2E on real hardware has
produced **4 real bugs so far** (details below), all fixed.

### Commit chain on main (newest first)
```
6e83ba3  fix(android): R8 keep rules for notifications; init survives plugin failure (E2E) ← HEAD
8136236  perf(server): persistent OCR inference subprocess (E2E)
c10899a  fix(server): normalize double-encoded notebook ink; index it anyway (E2E)
d0862de  fix(client): resume install wizard state on settings re-entry (E2E)
44e327d  Merge feature/handwriting-search: server-side OCR handwriting search (v1.7.0)
f96bfbb  fix(server): declare pillow, emit ink_index deletes on uninstall (final review)
f130e06  fix(client): cover search parity, selection-search interaction (task 6 fix round 1)
91dd88c  feat(client): handwriting find bar, ink highlighting and home search
7a95a27  feat(client): handwriting search toggle and install wizard
7785b7b  test(client): pin sync case-folding and the v15 upgrade path
aac2dbe  test(client): migration version pins track schema 15
b2990e3  feat(client): ink index mirror, sync consumption and search service
--- origin/main is at 8173245 (v1.6.1) ---
```

---

## 3. Live system state

| Thing | State |
|---|---|
| **Server container** | `tangent-server` up + healthy, rebuilt with GPU passthrough |
| **GPU** | RTX 5070 visible in-container (`probe_gpu_visible() → True`), PIL 12.3.0 present |
| **OCR env** | **INSTALLED**, flavour `gpu`, 9.4 GB at `/data/ocr-env` (survives rebuilds) |
| **Index** | **248 rows / 10 notebooks, 0 error rows** — your real handwriting, e.g. *"Sept 2 1st … Well. This is my first entry into m. an application here."* (10 of 25 notebooks have actual strokes; the other 15 are empty `{"strokes":[]}`) |
| **Server suite** | 274 passed, 3 skipped |
| **Client suite** | 1602 passing, 1 skipped + exactly 5 known Windows-env failures (`single_instance_test.dart` ×4, `desktop_pdf_share_test.dart` ×1) |
| **flutter analyze** | No issues found |
| **Version** | Still **1.6.1** everywhere — the v1.7.0 bump happens at the release cut |
| **Devices** | Fold `100.92.184.58:5555` (reachable), tablet `R5GL65VR7JZ` (USB). Tab S11 Ultra not currently connected |
| **Compose** | New opt-in `server/docker-compose.gpu.yml`; run with `-f docker-compose.yml -f docker-compose.gpu.yml` |

---

## 4. IN FLIGHT right now — finish this first

**Release APK build was running** (`flutter build apk --release`) to validate fix #4 on device.

### Immediate next steps (in order)
1. **Confirm the APK built**, then install to the Fold:
   ```bash
   export PATH="$HOME/AppData/Local/Android/Sdk/platform-tools:$PATH"
   adb connect 100.92.184.58:5555
   adb -s 100.92.184.58:5555 install -r "C:/Users/Jeff/Documents/ADH2/client/build/app/outputs/flutter-apk/app-release.apk"
   ```
   ⚠️ **adb needs Windows-style paths** (`C:/...`), MSYS paths fail with "failed to stat".
2. **Device gate for fix #4 (owed, not yet done):** force-stop + relaunch, then logcat the
   new PID and confirm the `TypeToken ... IllegalStateException` is **GONE** and the process
   stays alive >10s:
   ```bash
   adb -s 100.92.184.58:5555 shell "am force-stop dev.tangent.tangent; sleep 2; monkey -p dev.tangent.tangent -c android.intent.category.LAUNCHER 1"
   adb -s 100.92.184.58:5555 shell "PID=\$(pidof dev.tangent.tangent); logcat -d --pid=\$PID | grep -iE 'TypeToken|flutter|sync'"
   ```
3. **Sabotage-prove fix #4's new tests** (owed): revert the init hardening → the 6 new
   "broken notification plugin never takes the app down" tests must go RED → restore GREEN.
4. **Append `## Fix 4` to `e2e-fix-report.md`** (the capped subagent never wrote it).
5. **Scoped re-review of `8136236..6e83ba3`** (fix #4 has had no independent review).

---

## 5. Jeff's E2E checkpoints (the actual gate for shipping)

Once the fixed APK is on the Fold:

1. Open Tangent, let it sync (pulls the 248-row index).
2. **Settings → Handwriting search.** Server already reports `installed: true` → one tap
   rests the toggle ON, **no reinstall, no dialog, no download**.
3. **Home screen:** search icon → type a word you wrote (e.g. something from Journal or
   To-Do) → matching notebooks list with **match count + snippet**.
4. Tap a result → opens **at the highlighted match**, find bar populated.
5. **next/prev** walks matches, current one visually distinct, wraps at the end.
6. **Linux desktop (AppImage)** — must search fine with no recognizer present (this is the
   whole reason we went server-side).
7. Optional repro of bug #1: start an install, leave Settings mid-install, come back →
   should show **live progress**, not an error.

**Known cosmetic behavior (parked, tell us if you hate it):** if an install finishes
*entirely* while you're away from Settings, the toggle rests OFF until one tap (which
flips it ON instantly). Auto-flipping was rejected because it would wrongly enable the
feature on *other* devices when one device installs.

---

## 6. The 4 E2E bugs found on real hardware (all fixed)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Leave Settings mid-install → return → can't toggle on, just an error | Wizard state was widget-local; re-entry ignored `install_running`, POSTed install → **409 rendered as hard error** | `d0862de` — init rehydrates from capability, 409 = attach-and-poll, never an error |
| 2 | Install succeeded, worker ran, **index stayed empty, zero errors, zero logs** | `notebooks.ink` was **double-encoded JSON** (Task 3's boot migration `json.dumps`'d payload ink that was already JSON text); worker's `isinstance(dict)` check silently treated it as "no strokes" | `c10899a` — migration single-encodes, idempotent boot repair (capped 10 peels), worker tolerates + **WARNS** (`ocr_worker.ink_unparseable`) instead of silent no-op |
| 3 | Backfill effectively never finishing | **39.1 s per line** — every line spawned a fresh subprocess that reloaded TrOCR; GPU inference itself is ~0.1 s | `8136236` — `--serve` mode loads model once + stdin/stdout line protocol, persistent child, per-line deadline, restart-once. **Measured: line1 31 s (load), then 0.53 s / 0.68 s — ~60×** |
| 4 | **"Tailscale is broken, can't connect to the server"** | Not the network at all (curl from the Fold over Tailscale worked). **R8 stripped gson generic signatures** → `flutter_local_notifications` threw `TypeToken must be created with a type argument` at init → init chain died → sync never started. Repo had **no ProGuard rules at all**; debug builds never shrink, so nothing caught it | `6e83ba3` — plugin's documented keep rules (pinned to 17.2.4, delete at v19+), wired into release buildType, **plus init hardening**: notification failure degrades to no-notifications + warning, never kills sync |

**Lesson worth keeping:** every one of these passed all suites. Green tests never proved the
feature worked on real hardware with real data.

---

## 7. Remaining release track (Task 7, after E2E sign-off)

1. Version bump **×4 sites** → `1.7.0`; `CHANGELOG.md`; `docs/next-iteration.md`.
2. `flutter build apk --release` → **apksigner DN check** must read `CN=Tangent, O=Tangent, C=US`.
3. RecordingService idle check; install to **all three devices** (Fold `100.92.184.58:5555` /
   `RFGL82VCV6V`, tablet `R5GL65VR7JZ`, Tab S11 Ultra `R52Y8032LWW`).
4. **Push main** (12 commits), tag `v1.7.0`, confirm **CI + Release workflows green**, verify
   release assets (`tangent-v1.7.0.apk` + `Tangent-x86_64.AppImage`).
5. Rebuild container at the tagged version; verify beacon reports `1.7.0`.
6. Update `docs/next-iteration.md` + add an OCR/search reference to the
   `tangent-app-development` skill (files, endpoints, invalidation rule, wizard flow).

---

## 8. Deferred minors (triaged: none block merge)

**From the final whole-branch review (13 items, all STAYS-DEFERRED)** — e.g. `_median_height`
computes bbox twice; env publish window can lose both envs on failure (single-user server,
seconds wide, Retry re-installs); boot re-scans ink-NULL notebooks; `stop_worker` 5 s join vs
120 s inference; `_decodeBbox` catches only `FormatException`; `searchNotebooks` loads the whole
index table (justified: one person's corpus); typed-block read via `getNotebookRow`; 10.0.2.2
fallback base URL on desktop; stale failure panel after retry.

**From the E2E fix re-review (5 new minors):**
1. Install completing while away leaves toggle OFF until one tap (defensible — see §5).
2. `_rehydrate` guesses flavour; a later Retry could silently switch cpu→gpu.
3. A permanently hung env costs 2×240 s per line, no cross-line circuit breaker.
4. `unlink` `PermissionError` could mask a real error in the unkillable-child edge.
5. Worker peels 1 decode layer vs repair's 10 (3+-layer rows on an un-booted old build).

---

## 9. Environment gotchas (save yourself the rediscovery)

- **Every shell:** `export PATH="$LOCALAPPDATA/flutter/bin:$PATH"` — background shells don't inherit.
- **adb:** `export PATH="$HOME/AppData/Local/Android/Sdk/platform-tools:$PATH"`; pass
  **Windows-style** APK paths.
- **Server tests:** `cd server && ./.venv-test/Scripts/python.exe -m pytest -q` → 274+3.
- ⚠️ `.venv-test` has hand-installed packages — it **masked the missing pillow declaration**
  that would have crashed the production container on every boot (caught by final review, fixed
  in `f96bfbb` with a boot-path import-audit test).
- **Container:** `/data` is the only mount; code changes need an image rebuild.
- `docker exec` python **cannot see** the uvicorn process's in-memory state — use
  `py-spy dump --pid 1` (needs `--privileged -u root`) for real thread introspection.
- Reset `client/linux/flutter/` + `client/windows/flutter/` generated churn before staging.
- **Standing rule:** sabotage-proof only against **committed** state — `git checkout --` on a
  file with uncommitted work destroys it (learned the hard way).

---

## 10. Verification standard in force

Non-negotiable, applies to every change: run the real gates and quote real output (full
`flutter test`, `flutter analyze`, server `pytest`); **sabotage-prove** every fix both
directions (break it → the named test goes RED → restore → GREEN); grep real symbols before
writing; **never trust a subagent's self-summary** — the controller independently re-verifies.
This standard is exactly what caught the pillow Critical, the stale-index Important, and all
four E2E bugs.

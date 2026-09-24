# Linux agent briefing — Tangent v1.7.1 (written 2026-09-22)

You are the Hermes agent on Jeff's Linux box (`jeff-cachyos`, CachyOS,
KDE Plasma Wayland, Tailscale `<linux-box-tailscale-ip>`). This file tells you
everything the Windows-side agent knows that you need, so you do not
re-derive it. Read AGENTS.md first for repo conventions.

## 1. What just shipped

- **v1.7.0** — handwriting search (server-side OCR, index syncs to every
  device, search runs locally/offline everywhere). Released earlier today.
- **v1.7.1** — patch on top, cut minutes ago. Two hardware-found fixes:
  1. **Ink-index backfill** (`e2095b7`): devices that synced on a pre-1.7.0
     build had their checkpoint already past the index entries → search
     said "No matches" forever. Server: `POST /v1/ocr/index/backfill`.
     Client: enabling handwriting search on an already-provisioned server
     posts it automatically.
  2. **Desktop default URL** (`900f726`): an unpaired desktop used to point
     at `10.0.2.2` (Android-emulator-only alias) and silently time out.
     Desktop default is now `http://localhost:8765` — which on THIS machine
     is wrong too (the server is remote), so **pair before testing**;
     the failure is at least instant and visible now.

## 2. Your job: E2E checkpoint 6 — handwriting search on Linux desktop

This is the LAST unverified checkpoint of the v1.7.0 arc and the whole
reason recognition is server-side (no on-device recognizer exists here).
Full context: `docs/next-iteration.md` §1.1.

Steps:

1. Download `Tangent-x86_64.AppImage` from the **v1.7.1** release:
   https://github.com/GyratingSeaCow/tangent/releases/tag/v1.7.1
   (NOT v1.7.0 — it lacks both fixes above.)
2. `chmod +x`, run it. Known-good on this exact desktop (v1.6.x verified:
   tray icon, global hotkey, close-to-tray).
3. **Pair first** — unpaired now fails fast at localhost:8765, it does not
   sync. Server: `http://<server-tailscale-ip>:8765` (win-jeff over Tailscale).
   Settings → server connection; pairing codes are in Settings on the
   server side (Settings → Pairing on any paired device, or ask Jeff).
   Do NOT test search while unpaired and report it broken.
4. Let sync finish (10 notebooks; the ink index arrives with
   `include_ink_index=true` pulls automatically — v1.7.1 clients need no
   backfill because the desktop pairs fresh, from seq 0).
5. Verify, in order:
   - search icon on Notebooks home AND inside a notebook;
   - query `that` → expect matches in **Journal (3)** and **new test (1)**
     with count + snippet (same corpus verified on Android today);
   - tapping a result opens the notebook at the highlighted match, on ink;
   - next/prev walks matches and wraps Ctrl+F-style;
   - NO install wizard reachable — desktop only consumes the synced
     index; Settings must not offer an OCR install here.
6. Report results to Jeff on Discord (channel `1362610711196598445`,
   mention `<@1232922889221836832>`) — pass/fail per bullet, screenshots
   welcome.

## 3. Facts that will save you time

- **Search matching is substring, case-insensitive** (`.contains()`,
  Ctrl+F semantics) — `that` legitimately highlights "that" inside longer
  words. Not a bug; documented contract in `lib/services/ink_search.dart`.
- The server container runs **1.7.1** on win-jeff (GPU compose). Its
  `/v1/server/info` needs auth; pairing mints a device token.
- The index is server-authoritative, **248+ rows / 10 notebooks**; the
  desktop never OCRs anything.
- If search comes up empty AFTER pairing + sync: check the server log for
  your `sync/pull?...include_ink_index=true` line and compare your
  `since_seq` against `SELECT MAX(seq) FROM change_log WHERE
  entity_type='ink_index'` — that diagnostic found the checkpoint-gap bug.
  A fresh pairing starts at seq 0, so this should be impossible here.
- Verification standard in this repo: real command output only, no
  self-reported success. See AGENTS.md and
  `docs/HANDOFF-v1.7.0-handwriting-search.md` §10.
- Secure storage on Linux needs a Secret Service (KWallet is fine on this
  box, v1.6.x already stored tokens). If reads throw, the app launches
  unpaired by design and explains in the connect screen.

## 4. Out of scope for you

- The Android devices (Fold + two tablets) are the Windows agent's job.
- Do not touch the server container config.
- The dumps-list redesign and other `next-iteration.md` items are not
  queued — checkpoint 6 only, then report.

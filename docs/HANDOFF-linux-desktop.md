# Handoff: Tangent Linux desktop companion (CachyOS)

> **Status (2026-09-20): substantially complete.** The client runs
> natively on CachyOS, packaged as an AppImage, with desktop features
> beyond the original brief (tray icon, global record hotkey,
> close-to-tray, right-click = long-press). See CHANGELOG.md
> `[Unreleased]` for the delivered list and the README Desktop section
> for user-facing docs. Delivered on `feature/linux-desktop`.
> Known deltas from the brief: the suite baseline moved from 1397 to
> 1456 tests (upstream v1.5.x landed mid-effort and desktop work added
> its own); `record_linux` 1.3.x uses parecord+ffmpeg, not fmedia, so
> the fmedia concern is moot.

You are picking up work on **Tangent**, a self-hosted voice/notebook app.
This document is self-contained — you need nothing from any prior
conversation. The human you are working with is **Jeff** (GitHub:
GyratingSeaCow). He is on the CachyOS machine with you; the Tangent server
and the Android work live on his Windows box.

## Mission

Get the existing Flutter client running as a **native Linux desktop app** on
this CachyOS machine, verify the notebook interactions with a real mouse
(drag, lasso, undo/redo — details below), fix the platform edges that
surface, and finally package it as an **AppImage**. The app is one codebase:
nothing here is a rewrite, it is porting/verifying the existing client.

## Ground rules (Jeff's standing expectations)

- **Real execution only.** "It should work" is not a result. Build it, run
  it, show real output. If blocked, report the actual blocker — never
  fabricate or paper over.
- **Fail loud.** No silent fallbacks. A tapped control that does nothing
  reads as a broken app; an error snackbar is always better than nothing.
- **TDD where tests are possible**: prove a test RED before implementing.
  For load-bearing tests, sabotage-check them (break the code, confirm
  exactly the right test dies, restore).
- **Gates before every commit**: `flutter analyze` clean (the lint set
  includes `require_trailing_commas` — run `dart format` after edits) and
  the full `flutter test` suite green. Current count: **1397 passing**.
  Do not weaken or delete existing tests to make them pass on Linux; if a
  test is genuinely Android-only, skip it with an explicit
  `skip:`-with-reason, never delete.
- **Branch discipline**: work on `feature/linux-desktop` off `main`. Do not
  push a red `main`. CI (GitHub Actions: Flutter analyze + test, server
  pytest) must stay green.
- **Line endings**: repo sources are CRLF (written on Windows). `.gitattributes`
  handling may vary — when scripting edits with sed/python, detect the
  newline style instead of assuming `\n`.
- Ask Jeff directly when you need a visual/manual check — he is at the
  machine and prefers doing device steps himself, with you verifying the
  result afterward.

## Repo

```bash
git clone https://github.com/GyratingSeaCow/tangent.git
cd tangent
git checkout -b feature/linux-desktop origin/main
```

`main` is current as of this handoff (`caa89a2`, release **v1.4.0**): the
full 2026-09 arc is merged and released — pen styles, smart lasso,
multi-step undo/redo, save-on-back, multi-device sync, server
discovery/pairing. `client/linux/` scaffold already exists (CMake runner).
Read `README.md` and `CHANGELOG.md` (the `[1.4.0]` section) for feature
context.

## Toolchain setup (Arch/CachyOS)

```bash
sudo pacman -S --needed base-devel clang cmake ninja gtk3 pkgconf xz unzip \
  libsecret jsoncpp mpv
```

Flutter: install ≥ 3.27 (Dart ≥ 3.6). Options: `yay -S flutter` (AUR), or
the official tarball into `~/development/flutter` and add `flutter/bin` to
PATH. Then:

```bash
flutter doctor          # fix anything it flags for "Linux toolchain"
cd client
flutter pub get
flutter analyze         # must be clean before you start
flutter test            # 1397 expected green ON LINUX — run this FIRST
```

Running the suite first matters: it has only ever run on Windows. If tests
fail on Linux before you change anything, that is baseline information, not
your bug — record it, fix what is cheap, skip-with-reason what is
platform-bound, and tell Jeff.

## Build and run

```bash
cd client
flutter build linux            # release bundle
# or for iteration:
flutter run -d linux
```

Expected first hurdles, in likely order:

1. **Plugin registration** — `flutter pub get` + the generated
   `linux/flutter/generated_plugins.cmake` should handle registered plugins.
   Plugins with no Linux implementation will just be absent; guard call
   sites with `Platform.isLinux` where needed.
2. **`flutter_secure_storage`** — on Linux it needs `libsecret` plus a
   running Secret Service. CachyOS with KDE: KWallet ≥ 5.97 provides the
   Secret Service interface (enable it in KWallet settings if the app can't
   store); GNOME: gnome-keyring. If no Secret Service is available the
   plugin throws — catch and surface a clear error, don't crash the connect
   screen.
3. **Playback (`just_audio`)** — has NO Linux backend. Add
   `just_audio_media_kit` + `media_kit_libs_linux` (bridges just_audio to
   libmpv) and call `JustAudioMediaKit.ensureInitialized()` on Linux at
   startup. Playback of downloaded/synced audio must work.
4. **Recording (`record` / `record_linux`)** — `record_linux` is already in
   pubspec but has never been exercised. Verify a real capture on this
   machine (it historically shells out to fmedia — if that's broken on
   current Arch, evaluate alternatives and discuss with Jeff before
   swapping plugins). Recording is important but the notebook work is the
   primary mission — do not let capture block the canvas verification.
5. **Storage paths** — Android uses SAF (folder grants). On Linux use real
   directories via `path_provider` (`~/.local/share/...` or
   `~/Documents/Tangent/`). The onboarding "authorize folder" step must not
   appear on desktop; check how `lib/data/storage/` branches per platform.

## What to verify on the canvas (the point of the app)

All of this is pure Flutter and already hardware-verified on Android — the
job is to prove it with a **mouse/trackpad** on desktop:

- Notebook editor: draw with mouse; pen-style picker (uniform / fountain /
  italic nib); stroke eraser
- **Smart lasso**: circle ink + text blocks + recording cards (>40% inside
  the loop selects); drag the selection; delete it; undo the move/delete
- **Multi-step undo/redo**: toolbar buttons, 100 deep, redo invalidated by
  new mutations
- Drag blocks/cards around the page directly
- **Save-on-back**: leaving the editor saves (no discard dialogs anywhere)
- Text notes, folders, cover-grid view

Watch specifically for desktop-only issues: scroll-wheel vs drag conflicts
on the endless page, hover effects, right-click, window resize
mid-gesture, and HiDPI scaling.

## Server pairing (the sync half)

Jeff runs the Tangent server on his Windows box, in Docker:

- **Tailscale**: `http://100.88.126.107:8765` — reachable if this machine
  is on his tailnet. Discovery ("Find my server") sweeps the local /24
  only, so over Tailscale use **manual entry** on the connect screen.
- **Same LAN**: the sweep should find it automatically — this is itself a
  test worth running.
- Pairing: tap Pair → a 6-digit code appears in the server's docker log on
  the Windows machine. **Jeff reads the code there** (he knows how) and
  types/relays it. Codes expire in 120 s — coordinate with him before
  tapping Pair. Wrong codes count down 5 attempts.
- After pairing, verify: server info loads, a synced recording's audio
  downloads and **plays** (exercises the media_kit work), notebook sync
  pulls/pushes.

## AppImage packaging (after the app works)

1. Bundle: `flutter build linux` output at
   `client/build/linux/x64/release/bundle/`
2. AppDir layout: bundle contents + `AppRun` (exec the binary), a
   `tangent.desktop` (Categories=AudioVideo;Utility;) and an icon (there are
   icon concepts in `docs/design/icon-*.html`; a simple PNG export is fine —
   ask Jeff which he prefers).
3. Include the libs ldd shows missing on a bare system — notably libmpv and
   friends if media_kit doesn't bundle them itself. GTK3 should be assumed
   present on the host.
4. Build with `appimagetool` (AUR: `appimagetool` or the released
   AppImage of it; needs `fuse2` to *run* AppImages on Arch).
5. Verify: launch the AppImage on this machine from a clean shell
   (`env -i DISPLAY=... ./Tangent-x86_64.AppImage` is a decent smoke test),
   check recording dir creation, pairing, playback.
6. Stretch goal (discuss with Jeff first): a CI job on ubuntu-latest that
   builds the AppImage and attaches it to GitHub Releases.

## Definition of done

1. `flutter analyze` clean + full suite green on Linux (with any
   platform-bound skips documented and justified)
2. App runs natively on this CachyOS machine; Jeff has personally verified
   the canvas list above with his mouse
3. Paired with his server; audio playback of a synced recording works
4. `Tangent-x86_64.AppImage` launches and passes the same smoke checks
5. Branch `feature/linux-desktop` pushed with clean history; CI green; PR
   or merge decision left to Jeff
6. Update `README.md` (Desktop section) + `CHANGELOG.md` (add a new
   `[Unreleased]` section above `[1.4.0]`) with honest state — only what
   was actually verified

## Known context that will save you time

- The test suite has one known flaky file on slow runners:
  `server_transcription_service_test.dart` (30 s timeouts under CI load).
  A rerun clears it; don't chase it as a real failure.
- `docs/next-iteration.md` tracks open candidates; don't start those.
- The Android SAF re-grant dance, adb devices, and anything mentioning
  "Fold" or "tablet" in docs are Windows/Android concerns — not yours.
- Server API surface is documented in the root README architecture diagram;
  pairing endpoints are `/v1/pair/request`, `/v1/pair/claim`,
  `/v1/server/info/public`.

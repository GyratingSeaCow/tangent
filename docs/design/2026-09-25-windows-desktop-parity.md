# Windows desktop parity

Approved scope (Jeff, 2026-09-25): option (b) — full Linux-desktop parity
on Windows: app runs and records, tray + close-to-tray, global record
hotkey, single instance, installer, CI release artifact.

## Task 0 findings (all empirical, on the bench, 2026-09-25)

The first-ever `flutter build windows` and smoke launch produced these
facts; every task below is grounded in them.

1. **Build toolchain** — bench builds need three things:
   - Flutter 3.27.1's `visual_studio.dart` doesn't know VS 2026 (major 18)
     and falls back to a "Visual Studio 16 2019" generator. Bench-local
     shim in `$LOCALAPPDATA/flutter/.../windows/visual_studio.dart`: major
     18 → `Visual Studio 18 2026` (a real generator in VS 2026's CMake).
     Re-apply after any `flutter upgrade`. CI's windows-latest runners
     carry VS 2022 (major 17) and use the stock path.
   - `CL=/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` — the
     14.51 STL hard-errors on `<experimental/coroutine>` which
     `permission_handler_windows` still includes. To be moved into
     `windows/CMakeLists.txt` as a compile definition so neither bench nor
     CI needs the env var.
   - ATL in the VS instance CMake resolves (18 BuildTools on the bench).
     The VS installer silently no-ops without elevation (exit 0, nothing
     installed — check `atlstr.h` on disk, never the exit code); use
     `Start-Process -Verb RunAs`, and `--wait` is rejected (exit 87) by
     the VS 2026 installer.
   - CMake resolves the generator to an INSTANCE by its own preference
     order; `CMAKE_GENERATOR_INSTANCE` is honored only when the generator
     comes from the environment too, and Flutter passes `-G` explicitly —
     so the instance cannot be pinned from the env. Whatever instance
     CMake picks must carry ATL.
2. **App runs** — window titled "Tangent", UI renders, sqlite + secure
   storage + all plugins load.
3. **Icon is the stock Flutter template** (`windows/runner/resources/
   app_icon.ico`, referenced by `Runner.rc` `IDI_APP_ICON`). Source art
   exists: `packaging/tangent-icon.svg`, `packaging/tangent.png`.
4. **Find my server sweeps the wrong subnet.** `_localIPv4()` returns the
   first non-loopback IPv4 in interface-enumeration order. The bench has
   Tailscale (100.88.126.107) and two WSL/Hyper-V host NICs (172.29.32.1,
   172.25.96.1) beside the real LAN (192.168.1.206); the sweep probes the
   wrong /24 and finds nothing. Android rarely has competing interfaces,
   which is why this never bit on phones.
5. **Opus capture is impossible on stock Windows.** `record_windows`
   1.0.7 maps opus → `MFAudioFormat_Opus` and asks Media Foundation for
   an encoder; Windows ships only an Opus DECODER. The plugin's only
   complete Windows encode path is AAC-LC. Recording start fails.

## Design

### W1. Audio: playback init + AAC-LC capture branch

- Add `media_kit_libs_windows_audio` beside the Linux lib;
  `initPlatformAudio()` initializes on Windows too.
- Recording: on Windows, `RecordingConfig` uses `AudioEncoder.aacLc` and
  a `.m4a` suffix. Introduce a single seam — e.g.
  `platformCaptureFormat()` → `(encoder, extension, contentType)` — used
  by the recorder AND every path that assumes `.opus` today (capture
  file naming, upload content-type, audio import allow-list, playback
  lookup). Linux/Android stay opus; the seam is the only branch point.
- Whisper accuracy is unaffected: the server decodes via ffmpeg; AAC-LC
  at the same capture bitrate is transparent to transcription.
- The Linux-only `CaptureEvidenceRecorder` wrap (PipeWire latency fix)
  stays Linux-only.
- Server: verify the upload path accepts `.m4a` (audio endpoints, mime
  checks, storage naming). Fix if it assumes opus.

### W2. Server discovery: interface ranking

`_localIPv4()` becomes a ranked choice, tested:

1. RFC1918 addresses on physical-looking subnets first — 192.168.0.0/16,
   10.0.0.0/8, then 172.16.0.0/12;
2. deprioritize known-virtual sources: Tailscale CGNAT (100.64.0.0/10),
   and 172.16/12 addresses whose interface name matches WSL / Hyper-V /
   vEthernet / VirtualBox / VMware patterns;
3. Tailscale-only (no RFC1918 at all) → no sweep, existing manual-entry
   error text (unchanged contract).

Pure ranking function over `(interfaceName, address)` pairs, unit-tested
with the bench's exact interface set (192.168.1.206 must win over
100.88.126.107, 172.29.32.1, 172.25.96.1 in any enumeration order).

### W3. Icon + assets

- Generate a multi-resolution `app_icon.ico` (16/24/32/48/64/128/256)
  from `packaging/tangent-icon.svg`; replace
  `windows/runner/resources/app_icon.ico`. `Runner.rc` already points at
  it — no code change.
- Tray icon (W5) reuses `assets/tray/tray_icon.png` (already an asset).
- Audit `Runner.rc` FileDescription/ProductName — item 1.3 fixed the
  window title; verify the version-info strings say "Tangent" too.

### W4. Single instance + global record hotkey

- Transport: localhost TCP with a port file at
  `%LOCALAPPDATA%\Tangent\instance.port` replacing the Unix socket on
  Windows, behind the existing `SingleInstanceServer` interface. Same
  commands: `show` / `toggle-record`. Stale-port-file handling: connect
  failure ⇒ claim ownership (bind, rewrite file).
- The 4 standing `single_instance_test.dart` failures are Unix-socket
  tests running on a Windows host; with the TCP backend they must pass on
  Windows natively. Expected standing-failure count after this arc: 5 → 1
  (desktop_pdf_share remains).
- Hotkey: Linux keeps KDE global shortcuts → `tangent --record`. Windows
  registers **Ctrl+Alt+R** in-process via `hotkey_manager`
  (RegisterHotKey), routed into the SAME command path the socket serves
  (`toggle-record`). `--record` CLI arg keeps working on Windows too
  (forwards to the owning instance and exits).
- Registration failure (hotkey taken) must not crash the app — log and
  continue; Settings-configurable binding is a follow-up, not v1.

### W5. Tray + close-to-tray

- `TrayService` gains a Windows backend via `tray_manager` (the
  libappindicator left-click objection that forced SNI on Linux is
  Linux-specific; Windows delivers left/right distinctly). Same menu
  contract: Open App / Start Recording / Exit; left-click opens the app.
- `windowManager.ensureInitialized()` and the close-to-tray path widen
  from `Platform.isLinux` to desktop (`isLinux || isWindows`).
- Exit in the tray menu is the one true quit, same as Linux.

### W6. Packaging + CI

- **Inno Setup** script under `packaging/windows/`: per-user install
  (no admin), Start Menu entry "Tangent", optional launch-at-startup
  checkbox, bundles the whole Release folder. Artifact:
  `tangent-setup-x64.exe`. Unsigned (self-hosted AGPL; MSIX signing
  hurts exactly this audience).
- Release workflow (`v*` tags) gains a `windows-latest` job mirroring
  the AppImage one: build → verify exe exists and versioninfo matches →
  compile installer → attach `tangent-setup-x64.exe` and a portable
  `tangent-windows-x64.zip`.
- CI (`ci.yml`) gains a Windows build smoke (build only, tests already
  run on ubuntu) — cheap insurance that the Windows target never rots
  again.

## Out of scope

OCR install wizard on desktop (never — desktop consumes the synced
index), Bluetooth mic routing (Android-only), MSIX/Store, code signing,
configurable hotkey UI.

## Test bar

Same as the Linux desktop arc: unit/widget tests for the ranking
function, capture-format seam, tray menu contract, hotkey→command
routing, TCP single-instance lifecycle; `flutter analyze` clean; full
client suite at baseline or better (expected: the 4 single-instance
standing failures flip to passing); server suite green if W1 touches the
server; on-bench E2E: record → transcribe (live container) → sync →
notebooks → handwriting search consume; sabotage proofs after commit,
per standing rule.

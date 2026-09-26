# AGENTS.md

This file tells AI coding agents (and humans) how to work on ADH2.

## Project summary

ADH2 is a self-hosted, offline-first voice brain-dump app built for ADHD brains. Flutter client (Android/Linux/Windows) + Python server (FastAPI + Whisper-large-v3). AGPL-3.0.

See [`README.md`](./README.md) for the public-facing overview.

## Working in this repo

### Do

- Read `README.md` and the relevant source before writing any code
- Follow the AGPL-3.0 license header convention (see [`LICENSE`](./LICENSE))
- Use Flutter conventions for the client (`client/`), Python/FastAPI for the server (`server/`)
- Commit small, atomic changes with clear messages
- Update the design spec when reality diverges from the plan

### Don't

- Don't add features not in the v1 spec without updating the spec first
- Don't commit `*.bin`, `*.gguf`, audio recordings, or anything under `data/` — see `.gitignore`
- Don't add cloud-only features without an offline-first equivalent
- Don't break the AGPL by adding closed-source dependencies

## Repo layout (planned)

```
ADH2/
├── client/                # Flutter app (Android, Linux, Windows)
│   ├── lib/
│   ├── android/
│   ├── linux/
│   ├── windows/
│   └── native/            # whisper.cpp bindings, JNI/FFI
├── server/                # FastAPI + Whisper server (Docker)
│   ├── app/
│   ├── tests/
│   ├── Dockerfile
│   └── docker-compose.yml
├── docs/
├── .gitignore
├── LICENSE                # AGPL-3.0
├── README.md
├── CONTRIBUTING.md
└── AGENTS.md              # ← you are here
```

## Status

Shipping — **v1.13.0** (see CHANGELOG.md). Client and server are both
implemented and tested (1939
Flutter tests, 511 server tests, 100 Kotlin tests). The client runs
natively on Linux AND Windows (tray icon, global record hotkey,
close-to-tray, single instance, right-click = long-press; AppImage and
Inno Setup installer under `packaging/`) — verified on CachyOS/KDE
Plasma Wayland and Windows 11; see the README's Desktop sections.

v1.13.0 adds **transcript search depth** (snippets + match counts on
search results, open-at-match with a prev/next match bar, highlights in
Edit and Listen mode, play from a match when word timings exist) and
**summary templates** (server-owned presets Meeting / Brain dump /
Lecture / Actions only + one Custom slot with a Settings editor;
"Summarize again" picker on detail and list; per-dump `summary_template`
synced with the absent-vs-null sentinel, client DB v19). See
`docs/design/2026-09-26-search-and-summary-templates.md`.

v1.12.0 adds **tap-to-hear**: transcripts get an Edit | Listen toggle;
Listen renders tappable words with karaoke highlighting, confidence
tinting, and a server-computed waveform scrubber. Word timestamps and
peaks ride a server-owned `transcript_timings` dump field (client DB
v18, absent-vs-null sentinel like the summary columns). Server-authored
sync changes now bypass the newer-wins gate — the recording device's own
completion timestamp used to shadow them. See
`docs/design/2026-09-25-tap-to-hear.md`.

v1.11.0 adds the **Windows desktop app** at full Linux parity: WAV
capture (Media Foundation has no Opus encoder), media_kit playback,
loopback-TCP single instance, Shell_NotifyIcon tray, Ctrl+Alt+R global
record hotkey, per-user `tangent-setup-x64.exe`. Find-my-server now
ranks interfaces (Tailscale/WSL adapters no longer hijack the sweep)
and probes the device's own address (self-hosted servers). See
`docs/design/2026-09-25-windows-desktop-parity.md`.

v1.10.0 adds a **Whisper model picker**: Settings lists all five sizes in
accuracy order with Installed badges, installs on demand with a download
prompt and progress, and the server swaps the active model without a
restart. Accuracy is identical either way — the GPU only changes speed.
See `docs/design/2026-09-25-whisper-model-selection.md`.

v1.9.0 adds **AI meeting summaries**: a local llama.cpp model (Qwen 3 4B
Instruct 2507) on the server summarizes meeting transcripts — decisions,
action items, open questions — and the summary syncs to every device and
can be imported into notebooks. Off by default behind an install wizard,
mirroring handwriting search. See `docs/design/2026-09-24-ai-summaries.md`
and `docs/design/2026-09-24-summary-notebook-import.md`.

v1.7.0 adds **handwriting search**: server-side OCR indexes notebook ink,
the word index syncs down to every device, and search itself runs locally
and offline everywhere (including Linux desktop, which has no on-device
recognizer — that is precisely why recognition is server-side). The feature
is off by default behind an install wizard. See
`docs/design/2026-09-21-handwriting-search-ocr.md` for the approved spec.

Open work candidates live in `docs/next-iteration.md`.

---

*This file is for AI agents and humans alike. Update it when conventions change.*
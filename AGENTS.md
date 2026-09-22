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

Shipping — **v1.7.1** (see CHANGELOG.md). Client and server are both
implemented and tested (1623
Flutter tests, 284 server tests, 100 Kotlin tests). The client now runs
natively on Linux (tray icon, global record hotkey, close-to-tray,
right-click = long-press, AppImage packaging under `packaging/`) —
verified on CachyOS/KDE Plasma Wayland; see the README's Desktop
section.

v1.7.0 adds **handwriting search**: server-side OCR indexes notebook ink,
the word index syncs down to every device, and search itself runs locally
and offline everywhere (including Linux desktop, which has no on-device
recognizer — that is precisely why recognition is server-side). The feature
is off by default behind an install wizard. See
`docs/design/2026-09-21-handwriting-search-ocr.md` for the approved spec.

Open work candidates live in `docs/next-iteration.md`.

---

*This file is for AI agents and humans alike. Update it when conventions change.*
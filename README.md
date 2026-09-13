# ADH2 — Brain Dump Voice App

> **Talk. We remember.**
> Voice notes → searchable text → your second brain.
> Built for ADHD minds. Self-hosted. Offline-first. No subscriptions.

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](./LICENSE)
[![Status: v1 in design](https://img.shields.io/badge/status-v1%20in%20design-yellow.svg)]()

---

## What is this?

ADH2 is a **voice-first brain dump** app. You tap a big red button, ramble for 30 seconds or 30 minutes, and the app:

1. **Saves the recording locally** on your device (always, even offline)
2. **Transcribes it** using either your phone's on-device Whisper model, or your self-hosted server with bigger models
3. **Indexes the text** for full-text search
4. **Syncs to your server** when the network returns, with a batched "Confirm to Transcribe All" notification

It's the voice-capture + searchable-archive piece that no current app gets right for ADHD users. The closest competitors — Otter, Plaud, Audionotes — all charge monthly fees, lock you to their cloud, and were never designed for how ADHD brains actually work.

---

## Why does this exist?

We (the r/ADHD community, the r/selfhosted community, and one ADHD developer) noticed three patterns:

1. **People want to brain-dump but hate typing.** Every "best ADHD app" thread names voice capture. Existing voice apps are cloud-locked and expensive.
2. **People want self-hostable everything.** The "anti-cloud" trend — offline-first, local-only versions of popular apps — shows up in 7% of all "I wish this existed" posts.
3. **No one has glued voice → text → searchable local archive together in a way that works offline-first and self-hostable.** Three problems, each with50 apps. The intersection has *zero*.

So we're building it.

---

## What's in v1?

| ✅ In v1 | ❌ Not in v1 (yet) |
|---|---|
| Voice capture (Android, Linux, Windows) | Folder/tag organization (v2) |
| Local-first audio storage (Opus/AAC) | Auto-routing to Trello/Todoist (v2) |
| On-device Whisper (`small` model, ~460 MB) | Body-double nudger / meal tracking (v3) |
| Optional self-hosted server (Docker Compose) | Speaker diarization on-device (v2) |
| Auto-transcribe (server if reachable, else on-device) | Cloud sync across devices (v3) |
| Batched sync notification: "Confirm to Transcribe All" | Encryption at rest (v2) |
| Searchable dump list | |
| Model manager: "Need more accuracy? Download a bigger model!" | |
| Single-user server, AGPL-3 | |

---

## Status

🚧 **v1 is in design phase.** No code yet. We're working through a brainstorming spec right now.

When v1 ships, this README will have:
- APK download link
- `docker compose up` instructions for the server
- Screenshots
- Contributing guide

---

## Architecture (planned)

```
┌─────────────────────────────────────────────────────────────┐
│ ADH2 Mobile/Desktop Client (Flutter)                        │
│ • Record button → local Opus/AAC → SQLite + audio file      │
│ • Auto-transcribe via best-available backend                │
│ • Local FTS5 search                                         │
│ • Sync engine: detect connectivity → batch → server         │
└──────────────────────┬──────────────────────────────────────┘
                       │ HTTPS (when online)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ ADH2 Server (Docker Compose)                                │
│ • FastAPI + SQLite (single user, single binary)             │
│ • whisper-large-v3 with speaker diarization                 │
│ • Token-based auth (per-installation secret)                │
│ • Optional: nginx reverse proxy + TLS                       │
└─────────────────────────────────────────────────────────────┘
```

---

## License

[AGPL-3.0](./LICENSE). Self-hosted = source-available. If you fork it and run a public service, you have to publish your changes. That's the whole point.

---

## Acknowledgments

- **r/ADHD** — for the years of "I just want an app that…" threads that made the gap obvious
- **r/selfhosted** — for proving the offline-first community is real and growing
- **whisper.cpp** — for making local Whisper inference actually work on phones
- **Immich** — for showing the world what a self-hosted, community-loved app looks like
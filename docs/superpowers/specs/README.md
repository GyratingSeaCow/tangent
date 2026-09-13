# ADH2 Design Specs

This folder holds the design documents for ADH2. Right now (Sep 2026) we're in the **brainstorming phase** for v1.

The final spec will be written to `2026-09-13-v1-brain-dump-design.md` (date stamp TBD when written).

## What's locked in already

| # | Decision | Date |
|---|---|---|
| 1 | Scope = phased platform (v1 / v2 / v3) | 2026-09-13 |
| 2 | Repo: `~\Documents\ADH2`, git initialized | 2026-09-13 |
| 3 | Client stack = Flutter | 2026-09-13 |
| 4 | Storage model = self-hosted per-user, offline-first | 2026-09-13 |
| 5 | On-device default = `whisper.cpp` `small`; server fallback | 2026-09-13 |
| 6 | Sync = batched notification, "Confirm to Transcribe All" | 2026-09-13 |
| 7 | v1 feature floor (10 features, 7 cuts) | 2026-09-13 |
| 8 | Onboarding = 3 screens max, no model picker | 2026-09-13 |
| 9 | First-launch flow approved | 2026-09-13 |
| 10 | License = AGPL-3.0 (LICENSE file written) | 2026-09-13 |

## Still to decide

- Recording screen UX (tap vs hold, visual feedback, max length)
- Dumps list + search UX
- Settings screens (server config, model manager)
- Sync notification timing/logic (Wi-Fi only? battery thresholds?)
- Architecture: app ↔ server API shape, auth (token vs OAuth), data sync conflict resolution
- Repo layout (mono-repo app+server? separate repos?)
- Final name for the app (currently ADH2 as working codename)

---

*This README updates as brainstorming progresses. Last edit: 2026-09-13.*
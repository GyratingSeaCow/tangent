# Next iteration — open items ledger

Verified against the tree 2026-10-01 (v1.43.0). Every item from the v1.3-era
ledger (pairing-code display on connected devices, pen side-button eraser,
hover cursor, lasso footprint measurement, voice calendar events, voice
matching) has shipped — confirmed by grep against `client/lib` / `server/app`.

## Open

| # | Item | Size | Blocker / owner |
|---|------|------|-----------------|
| 1 | **Morning Brief live-E2E** — v1.43.0 shipped with contract tests (fakes) only. Needed on the real container: Qwen3-4B output quality on a heavy day, the honest short line on an empty-capture day, and an adversarial no-invention probe on the brief prompt (per docs/design/2026-10-01-morning-brief.md §Verification). | S | Container must run 1.43.0 first; Jeff rebuilds (see #2) |
| 2 | **Server container rebuild to 1.43.0** — running container advertises its build-time version until rebuilt; Morning Brief endpoints + 05:00 scheduler don't exist until then. | XS | Jeff's step (PS command; agent-run builds stall in CUDA wheel downloads) |
| 3 | **v1.43.0 release asset check** — CI + Release workflows on the tag green, `gh release view v1.43.0` lists all three client assets (APK, Windows setup, AppImage) + GHCR image `1.43.0`. | XS | ~15 min after tag push |
| 4 | **In-app screenshot user guide** — per-screen screenshots (Fold) with button-by-button function docs, committed to the repo; settings = one overview screenshot only. | M | In progress this run |
| 5 | **Docs overhaul merge** — `feature/docs-overhaul` (stale-claim fixes + fluff removal) review + merge. | S | In progress this run (Ted drafting) |

## Rulings

- 2026-10-01 Morning Brief decisions are final (docs/design/2026-10-01-morning-brief.md): 05:00 pre-generation, hidden-when-uninstalled (no teaser), narrative + bullets, no invention.
- Old handoff docs stay in git history (paths/serials, no secrets) — Jeff ruled no rewrite.

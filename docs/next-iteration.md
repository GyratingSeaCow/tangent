# Next iteration — open items ledger

Verified against the tree 2026-10-01 (v1.43.0). Every item from the v1.3-era
ledger (pairing-code display on connected devices, pen side-button eraser,
hover cursor, lasso footprint measurement, voice calendar events, voice
matching) has shipped — confirmed by grep against `client/lib` / `server/app`.

## Open

| # | Item | Size | Blocker / owner |
|---|------|------|-----------------|
| 1 | **Morning Brief prompt polish (minor):** the brief phrased the recording *title* "Jeff Labeled" as a meeting attendee ("a meeting with Jeff Labeled"). All cited facts were grounded; this is title-vs-person disambiguation in the aggregate prompt, not invention. Optional tweak. | XS | None — Jeff's call whether it bothers him |
| 2 | **Flutter SDK upgrade arc** — the repo pins Flutter 3.27.1 / Dart 3.6 (Dec 2024). 130 package updates are now held back by that floor, incl. Dependabot PRs #6 (flutter_lints 6, needs Dart ≥3.8) and #7 (riverpod 3, real migration). One arc: bump Flutter stable → re-pin CI + bench + Docker builder → let Dependabot re-group → take riverpod 3 as its own follow-up. Until then #6/#7 **cannot merge** (SDK floor), and PR #5 was superseded by a lockfile commit (its 25 "minor" bumps were mostly Dart-3.9+ or breaking majors; only flutter_secure_storage 9.6.2 was actually in-constraint). | L | None — schedule when Jeff wants an infra arc |

## Done 2026-10-01 (v1.43.0 arc)

- **Morning Brief live-E2E — PASSED** on the rebuilt 1.43.0 container
  (`Qwen_Qwen3-4B-Instruct-2507-Q4_K_M`): heavy days 2026-10-01/02 produced
  grounded narrative + highlights (every claim traced to stored dumps);
  empty day 2026-08-15 returned the honest short line with `model: none`
  (LLM never invoked). Auth gate verified (anon 401); regenerate path
  202 + background thread confirmed.
- Container rebuilt by Jeff; `/v1/server/info/public` reports 1.43.0.
- Release assets verified: all three client assets on the v1.43.0 release,
  GHCR `1.43.0` anonymously pullable (manifest 200).
- Screenshot user guide shipped (`docs/user-guide/`, Jeff-approved set).
- Docs overhaul merged (README set de-fluffed, claims grep-verified).

## Rulings

- 2026-10-01 Morning Brief decisions are final (docs/design/2026-10-01-morning-brief.md): 05:00 pre-generation, hidden-when-uninstalled (no teaser), narrative + bullets, no invention.
- Old handoff docs stay in git history (paths/serials, no secrets) — Jeff ruled no rewrite.

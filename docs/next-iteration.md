# Next iteration — open items ledger

Verified against the tree 2026-10-01 (v1.43.0). Every item from the v1.3-era
ledger (pairing-code display on connected devices, pen side-button eraser,
hover cursor, lasso footprint measurement, voice calendar events, voice
matching) has shipped — confirmed by grep against `client/lib` / `server/app`.

## Open

| # | Item | Size | Blocker / owner |
|---|------|------|-----------------|
| 1 | **Morning Brief prompt polish (minor):** the brief phrased the recording *title* "Jeff Labeled" as a meeting attendee ("a meeting with Jeff Labeled"). All cited facts were grounded; this is title-vs-person disambiguation in the aggregate prompt, not invention. Optional tweak. | XS | None — Jeff's call whether it bothers him |
| 2 | **Flutter SDK upgrade arc** — upgraded the repo pin to Flutter 3.47.6 / Dart 3.13 (Sep 2026) and refreshed the lockfile without taking Dependabot PRs #6 (flutter_lints 6) or #7 (riverpod 3, real migration). Those majors remain separate follow-ups. | L | Implementation complete; verification pending |

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

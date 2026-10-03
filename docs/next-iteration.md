# Next iteration — open items ledger

Verified against the tree 2026-10-01 (v1.43.0). Every item from the v1.3-era
ledger (pairing-code display on connected devices, pen side-button eraser,
hover cursor, lasso footprint measurement, voice calendar events, voice
matching) has shipped — confirmed by grep against `client/lib` / `server/app`.

## Open

| # | Item | Size | Blocker / owner |
|---|------|------|-----------------|
| 1 | **Morning Brief prompt polish (minor):** the brief phrased the recording *title* "Jeff Labeled" as a meeting attendee ("a meeting with Jeff Labeled"). All cited facts were grounded; this is title-vs-person disambiguation in the aggregate prompt, not invention. Optional tweak. | XS | None — Jeff's call whether it bothers him |
| 2 | **riverpod 3 migration** (Dependabot #7) — real API migration, its own arc. | M | Unblocked by the SDK merge |
| 3 | **Dependabot wave**: flutter_lints 6 (#6) + the ~130 held-back package updates — let Dependabot re-group against the 3.47 floors, take in batches. | S | Unblocked by the SDK merge |
| 4 | **fdroiddata recipe srclib bump** — next release tag is built with the new chain, so !50943's recipe (or its first update MR) must move `flutter@3.27.1` → `flutter@3.47.6`. | XS | Required at next release / F-Droid review |

## Done 2026-10-02 (v1.48.0 + SDK arc)

- **v1.48.0 shipped** (metadata-only): fastlane tree + `fdroid-changelog`
  release gate; all 3 assets + GHCR green. **Submitted to F-Droid:**
  [fdroiddata !50943](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/50943)
  (daily MR watch cron active).
- **Flutter SDK arc merged** (`14103ce`): 3.27.1 → 3.47.6 pins everywhere,
  SDK floors ≥3.47/≥3.10, Android chain AGP 9.1 / Kotlin 2.4 / Gradle 9.3.1 /
  Java 17 / desugaring. Gates: flutter test +2885/0, Kotlin 129/129,
  release rehearsal 37068202237 all-green, CI on merge green.
- **Widget restyle merged** (`5382e24`): notebook/record widget hardcoded
  values extracted to res/values (+night), dialogs on R.string.

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

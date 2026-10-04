# Next iteration — open items ledger

Verified against the tree 2026-10-03 (v1.48.2). Every item from the v1.3-era
ledger (pairing-code display on connected devices, pen side-button eraser,
hover cursor, lasso footprint measurement, voice calendar events, voice
matching) has shipped — confirmed by grep against `client/lib` / `server/app`.

## Open

| # | Item | Size | Blocker / owner |
|---|------|------|-----------------|
| 1 | **Morning Brief prompt polish (minor):** the brief phrased the recording *title* "Jeff Labeled" as a meeting attendee ("a meeting with Jeff Labeled"). All cited facts were grounded; this is title-vs-person disambiguation in the aggregate prompt, not invention. Optional tweak. | XS | None — Jeff's call whether it bothers him |
| 2 | **riverpod 3 migration** (Dependabot #7) — real API migration, its own arc. | M | Unblocked by the SDK merge |
| 3 | **permission_handler 13** — needs compileSdk 37, above AGP 9.1.0's max-recommended 36. Take with the next Android toolchain bump. | XS | Upstream (AGP) |
| 5 | **tray_manager 0.7** — nativeapi-based API rewrite; `lib/services/win_tray.dart` needs a real migration (global `trayManager` gone, TrayListener no longer a mixin, Menu/MenuItem constructors changed). | S | None — small arc |
| 4 | **plus-family dependency knot** — connectivity_plus 7 / device_info_plus 13 / share_plus 13 / flutter_secure_storage 11 / flutter_timezone 5 / dbus 0.8 only resolve together with a flutter_local_notifications DEV PRERELEASE (23.0.0-dev.x needs dbus ^0.8; 22.x stable needs ^0.7). Deferred until fln 23 stable; discontinued `js` stays in the graph until then. | S | Upstream (fln stable release) |
| 6 | **Shared tags follow-ups** (feature branch `feature/shared-tags`, spec docs/design/shared-tags.md): bulk tagging from the multi-select toolbars; merging same-named tags created offline on two devices; sweeping assignments of permanently deleted recordings; tags in search/Ask/MCP/exports. Hardware acceptance of tag sync between the two devices is still owed. | S–M | None |

## Done 2026-10-03 (F-Droid review loop + v1.48.1/v1.48.2)

- **Dependency wave MERGED to main** (`1082a19`, 7 gated batches): go_router 18, intl 0.20, just_audio 0.10, record 7, workmanager 0.10, flutter_lints 6, codegen+drift majors, in-constraint sweep. Merged-tree gates: +2885/0, analyze 0 errors, clean debug APK (stale incremental Kotlin state needed one `flutter clean`).

- **F-Droid MR !50943 pipeline fully green** (all 9 jobs incl. `fdroid
  build` + `check apk` — F-Droid's own builder compiles Tangent).
  Review iterations handled same-day: template conformance
  (build-flutter.yml srclib shape, reviewer linsui), rewritemeta
  canonical form, rm-glob fix, remove_signing_keys multiline-ternary
  fix (v1.48.1), Google dependency-info block dropped (v1.48.2).
- **v1.48.1 + v1.48.2 shipped** (patch releases for the above; all
  assets + GHCR green both times).
- **srclib bump item OBSOLETE**: the recipe now seds the flutter pin
  out of ci.yml at build time — SDK bumps need no recipe edit.
- **Rebrand**: "Voice/Text Brain Dumps" across README title (Jeff's
  PR #12), F-Droid short_description, pubspec description.
- **Dependency wave batches 1–3 on `feature/dependency-wave`**:
  in-constraint upgrades; codegen+drift stack majors (build_runner
  2.16, freezed 4, drift 2.35, sqlite3 3 — build_resolvers/
  build_runner_core discontinued deps dropped); flutter_lints 6.
  Tip re-verified: +2885/0, analyze 0 errors.

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

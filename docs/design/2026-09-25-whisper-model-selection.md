# Whisper model selection

Status: APPROVED (Jeff, 2026-09-25: the Server transcription settings section
"isn't reflecting the choices properly. It's listing them but not letting you
select them, doesn't prompt you which ones to install etc.")

## Problem

Settings → Transcription shows one read-only status line whose subtitle reads
`Connected · default model: large-v3 · available: tiny, base, small, medium,
large-v3 · N dumps`. The "available" list looks like a menu but nothing is
selectable: there is no client picker, **no server endpoint to change the
model**, and no install flow — the model is fixed by `TANGENT_WHISPER_MODEL`
at container start and weights download silently from HuggingFace on first
use (a multi-GB stall with no progress anywhere).

## Requirements

### Server

1. **Persisted selection overrides the env default.** New `app_settings` key
   `whisper_model`. Resolution order: `app_settings` value (if present and
   in `SUPPORTED_MODELS`) → `settings.whisper_model` (env) → `large-v3`.
   Add `resolve_active_model(db)` next to the existing
   `SUPPORTED_MODELS` / `is_supported_model` in `services/storage.py`, and
   make `TranscriptionService` resolve through it at load time rather than
   reading config directly.
2. **`GET /v1/transcription/models`** → `{"active": "<name>", "models":
   [{"name","installed","size_bytes_on_disk","approx_download_bytes"}]}`
   in accuracy order `large-v3, medium, small, base, tiny`. `installed`
   is true when `/data/models/models--Systran--faster-whisper-<name>`
   exists AND contains a `model.bin` (a partial download is NOT installed).
   `approx_download_bytes` is a static table (large-v3 ~3.1 GB, medium
   ~1.5 GB, small ~484 MB, base ~145 MB, tiny ~75 MB) — documented as
   approximate, used for the client's confirm copy.
3. **`PUT /v1/transcription/model`** `{"name": "<name>"}` → 200 with the
   same body as GET. 400 for an unsupported name. **409** when that model
   is not installed (client must install first — mirrors the summaries
   regenerate contract). Writes `app_settings`, logs
   `transcription.model_selected`.
4. **`POST /v1/transcription/models/{name}/install`** → `{"status":
   "installing"}` / 409 if an install is already running / 400 unsupported.
   Downloads via faster-whisper's own loader into `/data/models`, in a
   worker thread, with progress. **Installing does NOT change the active
   model** — selection stays an explicit second step.
5. **`GET /v1/transcription/models/install/progress`** →
   `{"phase","percent","detail","model"}`, phases
   `idle|downloading|verifying|done|failed`, mirroring the summaries
   progress contract exactly. A failed install leaves no partial dir
   (atomic: download to a temp dir, move into place on success).
6. **`DELETE /v1/transcription/models/{name}`** removes weights from disk.
   **409 if it is the active model** — never leave the server unable to
   transcribe.
7. **The active model swaps without a container restart**: the next job
   loads the newly selected model (the service already lazily loads and
   caches; invalidate the cached instance on selection).

### Client

8. **Replace the read-only subtitle** with a `WhisperModelSection` under the
   Transcription header. Status line shrinks to `Connected · N dumps`
   (+ error/unreachable states unchanged).
9. **Radio list, accuracy order**, one row per model:
   `large-v3` "Most accurate — recommended · ~3.1 GB", `medium`, `small`,
   `base`, `tiny` "Fastest, least accurate · ~75 MB". Each row shows an
   **Installed / Not installed** badge; the active one is the selected
   radio.
10. **Selecting an installed model** PUTs immediately and shows a
    `Now transcribing with <name>` snackbar. **Selecting an uninstalled
    model** opens a confirm dialog naming the download size, then POSTs
    install → inline progress + notification (id **1004**, channel
    `whisper_model_install`) → on `done`, PUT the selection automatically
    and snackbar. Install failure surfaces the server's error text with a
    Retry affordance; the radio falls back to the previously active model.
11. **Accuracy-first copy** (Jeff's standing preference): rows lead with
    accuracy, never with speed. No row implies a smaller model is "better
    for most people".
12. **Rehydration**: reopening Settings during an install re-attaches to
    the progress (GET progress on init), exactly like the summaries wizard.
13. **Offline/unreachable server**: the section renders the rows disabled
    with the last known active model and an explanatory line; it never
    crashes or shows an empty list.

## Non-goals

- No per-recording model override.
- No diarization/model-quality changes; this is selection plumbing only.
- No automatic eviction of unused weights (delete is manual, requirement 6).

## Verification (binding — tangent-app-development standard)

- Server: pytest per endpoint incl. 409-not-installed, 409-delete-active,
  400-unsupported, atomic-failure-leaves-no-dir, resolution order
  (app_settings > env > default), and that selection invalidates the cached
  service. Full server suite vs the 411-passed baseline.
- Client: widget tests for the radio list, badges, install-then-select
  flow, confirm-dialog copy (size named), rehydration, disabled/offline
  state. Full `flutter test` vs the +1745 ~1 -5 baseline (known 5 by name);
  `flutter analyze` clean.
- Commit green work BEFORE sabotage; at least one sabotage per side
  (suggested: drop the 409-not-installed guard; drop the install→select
  chaining) RED/GREEN quoted.
- Live E2E on the real server before release: install `small`, select it,
  transcribe a recording with it, select `large-v3` back, delete `small`.

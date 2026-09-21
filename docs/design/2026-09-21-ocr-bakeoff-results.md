# OCR bake-off results — Task 0 gate (2026-09-21)

Sample: Jeff's real handwriting, notebook "new test" (8048ecdb), written on
the Tab S11 Ultra — 148 pen strokes / 15,038 points, cursive-leaning,
clustered into 4 lines by `server/tools/ocr_bakeoff.py`.

Ground truth (what Jeff wrote):

1. "testing out the only thing thats actually"
2. "worth keeping around in the"
3. "entire app. If this doesn't work, then"
4. "idk what else to do to build the app."

## Transcriptions

| # | base (CPU / RTX 5070) | large (CPU / RTX 5070) |
|---|---|---|
| 1 | testing **over** the only **thin** that actually — 0.82s / 0.46s | testing **our** the only **thin** . Thats actually — 1.59s / 0.12s |
| 2 | " worth keeping around in the — 0.54s / 0.07s | I worth **keepin** around in the — 1.07s / 0.10s |
| 3 | entire app . If this doesn't work , then (perfect) — 0.93s / 0.12s | **entime** app . If this does not work , then — 1.38s / 0.13s |
| 4 | **idic** what else to do to build the app . — 0.88s / 0.11s | **idic** what else to do to build the app . — 1.35s / 0.13s |

Identical text CPU vs GPU per model (same weights); only latency differs.

## Findings

- **base ≥ large on this handwriting.** base: perfect on line 3, cleaner on
  lines 1–2. large introduced errors base didn't make ("entime", "keepin",
  "our"). Word error rate ~ base 3/24, large 6/24.
- Shared failure modes: "out"→over/our, "thing"→thin, "idk"→idic —
  connected/abbreviated forms.
- Search impact: content words a user would search ("testing", "keeping",
  "entire", "app", "build") land correctly in base on every line.
- Latency: CPU ~0.5–0.9s/line (base) is comfortably fine for background
  indexing; GPU ~0.1s/line.
- Env facts for Task 2 installer: TrOCR needs `sentencepiece` + `protobuf`;
  **transformers must be pinned `>=4.46,<5`** (5.x drops the legacy
  tokenizer-conversion path TrOCR's hub files need); cu128 wheel line works
  on the RTX 5070 (Blackwell), CUDA visible, torch 2.14.0.

## Ruling

- Model gate: PASSED — TrOCR reads Jeff's handwriting well enough for
  search. VLM escalation not needed.
- Flavour decision (Jeff, 2026-09-21): both flavours ship
  `microsoft/trocr-base-handwritten` — large offered no accuracy gain on
  the real sample and base is smaller and faster. GPU install = same model
  on CUDA (fast backfill); the flavour split is now about compute, not
  weights. Spec §3.2 amended accordingly.

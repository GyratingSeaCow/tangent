# Next iteration

Work agreed but deliberately not started, so it is not carried in conversation
alone. Each item states what is already true, so the next session does not
re-derive it.

---

## 1. Open items

None. The board is clear as of 2026-09-21 — every candidate from the last
sweep shipped in v1.6.0/v1.6.1.

Remaining ideas are all **hardware-feedback-gated** (Jeff drives, no work
queued): hover-ring linger/thickness tuning if 250 ms feels wrong on device;
toolbar `visualDensity.compact` eyeball; flip-to-erase only if this pen ever
emits `invertedStylus`. New arcs come from daily-use annoyances.

## 2. Done (2026-09-21, v1.6.0 → v1.6.1)

- v1.6.0 cut: pen colours + highlighter (6-task SDD arc), notebook image
  import, Linux desktop AppImage via CI, all version sites reconciled.
- Eraser reach follows the rendered highlighter band (`d298386`).
- PDF export renders imported images, corrupt-bytes fallback (`9b5bdf3`).
- Pairing codes in Settings — no more docker-log reading (`117a305`);
  server display_name renamed "Tangent Server" (was "Jeff"), setup hint
  now says to name the machine, not yourself.
- Pen hover cursor, phase 6 (`ebaf43e`): honest-radius ring (pen width /
  highlighter band / eraser reach), stylus-only, cleared on contact,
  lasso-mode exempt (`9f038a2`). Phase 5 (side-button eraser) discovered
  already shipped in `_isErasing`.
- Lasso measures real block footprints via RenderBox (`3020553`); dump
  cards stay on the nominal 300×90 the 40% threshold was tuned against.

## 3. Done (2026-09 arc, earlier)

- Pen input phases 1–4: palm rejection, pressure width, fountain pen
  (`f238d3a`), italic nib + gamma (`2b98407`) — hardware-verified.
- Smart lasso: ink + blocks/recordings, 40% catch threshold, drag/delete/
  undo (`3a06581`, `add5ce4`, `a11ebb1`, `4c8f349`).
- Multi-step undo/redo, 100 deep (`09a9b73`).
- Save-on-back everywhere, replacing discard dialogs (`e13ea6e`).
- DEBUG banner removed (`4c8f349`).
- Multi-device sync discovery/pairing (`4f352bc` server, `e01ad1e` client):
  unauthenticated `/v1/server/info/public` beacon, client /24 sweep ("Find
  my server"), 6-digit log-code pairing minting device-bound revocable
  tokens. E2E-verified against the live container and by Jeff on hardware.
- Pen-writes-without-draw-mode (`dea6b39`), lined page templates
  (`f0916cb`), dumps filter bar (`523bc47`), amplified capture
  (`8b65a6f` + `baa6a7f`) — all verified per 2026-09-19 status sweep.
- Keystore backed up to local NAS (2026-09-19).

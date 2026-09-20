# Next iteration

Work agreed but deliberately not started, so it is not carried in conversation
alone. Each item states what is already true, so the next session does not
re-derive it.

Status sweep 2026-09-19 (Jeff's answers):
- Amplified-capture item REMOVED at Jeff's direction (the code shipped in
  `8b65a6f` + `baa6a7f`; this doc's "uncommitted" status was stale).
- Pen-writes-without-draw-mode (`dea6b39`): verified by Jeff on the S10 —
  "functions pretty much flawlessly".
- Lined page templates: already implemented (`f0916cb`, schema v10).
- Dumps filter dropdown bar: shipped `523bc47`.

---

## 1. Pen input, remaining phases (ACTIVE 2026-09-19)

Design: `docs/design/pen-vs-finger-input.md` (measurements real; phases 1–2
shipped and hardware-verified). In scope now, per Jeff:

- **Palm rejection** (phase 3): pen-present window (~500 ms trailing after the
  last stylus event) during which touch neither draws, drags cards, nor
  scrolls. Engages only on devices that have actually produced stylus events —
  a phone with no pen must never suppress touch.
- **Pressure-varying stroke width** (phase 4): optional `p` on `InkPoint`,
  tapered rendering, legacy notebooks (no `p`) load and render flat.
- **NEW (Jeff, 2026-09-19): fountain pen option, similar to Samsung Notes.**
  A pen-style picker: the current uniform stroke stays the default, fountain
  renders pressure-tapered with stroke character. This is where the phase-4
  pressure data surfaces in UI.
- Side-button eraser (phase 5) and hover cursor (phase 6) remain later polish;
  flip-to-erase stays deferred (no `invertedStylus` observed on this pen).

---

## 2. Carried, not started

- Multi-device sync server discovery/pairing (designs in `docs/design/`,
  untracked and unreviewed).
- Jeff's own to-do: back up `C:\Users\Jeff\Documents\tangent-signing\`
  (signing keystore — unrecoverable if lost).

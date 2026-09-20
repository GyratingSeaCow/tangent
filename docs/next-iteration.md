# Next iteration

Work agreed but deliberately not started, so it is not carried in conversation
alone. Each item states what is already true, so the next session does not
re-derive it.

---

## 1. Open items

None. The board is clear as of 2026-09-20.

Candidate follow-ups discussed but NOT committed to:

- **Pairing-code display on connected devices**: `/v1/pair/pending` exists
  server-side (authenticated, returns pending pairings with codes), but no
  client UI consumes it — the docker log is currently the only place to read
  a pairing code. Small client-side follow-up if the PowerShell step annoys.
- **Pen polish, later phases**: side-button eraser (phase 5), hover cursor
  (phase 6); flip-to-erase stays deferred (no `invertedStylus` observed on
  this pen).
- **Lasso block footprint**: blocks are caught via a nominal 300×90 footprint;
  real render-box measurement is the next step only if wide text blocks
  annoy in practice.

## 2. Done (2026-09 arc)

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

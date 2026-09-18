# Next iteration

Work agreed but deliberately not started, so it is not carried in conversation
alone. Each item states what is already true, so the next session does not
re-derive it.

---

## 1. Finish the amplified-capture (microphone gain) fix

**Status: in progress, NOT shippable. The slider works; recording at any gain
above 1.0x does not.**

Found on the Galaxy Tab S10 FE, not by the suite. With gain at 4.0x the record
button did nothing: the PCM stream genuinely opened (logcat showed
`AudioRecorder` taking audio focus at 16 kHz mono) but no file appeared, the UI
never entered the recording state, and the recorder was left **wedged** so the
next recording failed too — even after dropping gain back to unity. Only an app
restart cleared it.

### Cause

A capture's content extension stopped being a pure function of the capture
*mode* when gain arrived: an amplified capture is PCM in a WAV container. But
`contentExtensionForMode(mode)` is still called independently from eight places,
each of which expects `<id>.opus` and therefore rejects the `.wav` the recorder
just wrote. Staging validation is the one that bites first.

Known call sites (grep `contentExtensionForMode` across `client/lib` **and**
`client/android` — a single-directory grep under-reports them):

- `services/recording_persistence.dart` (2 — staging validation, the blocker)
- `data/storage/filesystem_capture_io.dart` (2)
- `data/storage/filesystem_storage_backend.dart` (3)
- `data/storage/capture_publication_codec.dart` (1)

### Done already

- `contentExtensionForReservation(mode, stagingPath)` exists in
  `data/storage/storage_contract.dart` — derives the extension from the
  reservation's own staging path, falling back to the mode for an unrecognised
  name. **Uncommitted.**
- `test/unit/services/amplified_capture_validation_test.dart` pins the rule
  end to end against the real `SqliteStorageCatalog` (4 tests, passing).
- Kotlin already handles this correctly (`CapturePublication.contentSuffix`
  takes the staging path; 95 Kotlin tests pass, and reverting it to opus-only
  fails one).

### Remaining

1. Convert the eight Dart call sites to `contentExtensionForReservation`.
2. Release recorder resources on **every** start-failure branch, so a failed
   capture cannot wedge the next one. This is a separate defect from the naming
   bug and survives fixing it.
3. Full gates, then verify on hardware: record at 1.0x and 4.0x, confirm
   `.opus` vs `.wav`, both play back and both transcribe.

### Watch for

Gain is applied in Dart on the PCM stream. A long recording under load may drop
chunks in a way no unit test can reveal — the 4.0x hardware run is partly there
to surface that. If it appears, move the multiply into Kotlin.

---

## 2. Lined page templates for notebooks

Requested: a page template option offering **small** and **medium** lined
(ruled) pages, selectable per notebook, alongside the current blank page.

Nothing is built yet. Constraints that already apply:

- The notebook page is a Samsung-Notes-style growing vertical page with no
  `InteractiveViewer` and no pinch/zoom, so a rule line is a fixed device-pixel
  spacing, not a zoom-relative one.
- Ink stays **white**; rule lines must be a low-contrast chassis tone so they
  never compete with handwriting or read as the lime signal colour.
- Ruling is a per-notebook property and must persist — expect a schema column
  and a migration (`references/schema-migrations.md` before writing it).
- Existing notebooks must keep rendering exactly as they do now: the migration
  default is "blank", and a characterisation test should pin that first.
- Line spacing should be chosen against the pen, not guessed: the S Pen writes
  comfortably at a size that needs measuring on the Tab S10 FE before the two
  presets are fixed.

---

## 3. Carried, not started

- **Pen-writes-without-draw-mode (`dea6b39`)** — committed and gated at 1094
  tests, never validated on hardware. The S Pen should write anywhere on the
  page with draw mode off, while a finger still scrolls and taps normally.
- Palm rejection and pressure-varying stroke width (design in
  `docs/design/pen-vs-finger-input.md`, unimplemented).
- Multi-device sync and server discovery/pairing (designs in `docs/design/`,
  untracked and unreviewed).

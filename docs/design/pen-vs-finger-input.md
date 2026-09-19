# Pen vs finger input — design

Status: proposed. Measurements are real; the implementation is not written yet.

Notebooks are used with an active pen. Today the app cannot tell a pen from a
finger in any way that matters, and the code comment claiming otherwise is
wrong. This document records what the hardware actually reports and what to
build on it.

---

## 1. What the code does today (measured, not assumed)

`notebook_ink_canvas.dart` has `_acceptsDevice()`, documented as:

> Stylus input is always honoured while the canvas is active; touch and mouse
> only paint when draw mode is on.

**That is not what happens.** `_onPointerDown` starts with:

```dart
if (!widget.drawingEnabled) return;   // ← before the stylus check
if (!_acceptsDevice(event.kind)) return;
```

and the whole canvas is wrapped in `IgnorePointer(ignoring: !drawingEnabled)`.
So the pen is ignored exactly like a finger until draw mode is toggled on. The
stylus branch in `_acceptsDevice` is unreachable in the off state.

Characterisation tests in
`client/test/widget/notebook_stylus_characterisation_test.dart` pin this
current behaviour so the change is visible when it lands.

---

## 2. What the hardware reports

Measured on a Samsung Galaxy Tab S10 FE (`SM_X520`, Android 16) via a
throwaway probe app that logged raw `PointerEvent` fields. 648 events.

Android input device: `sec_e-pen`, sources `TOUCHSCREEN | STYLUS`, with axes
`PRESSURE`, `TILT`, `ORIENTATION`, `DISTANCE`. The touchscreen driver
(`sec_touchscreen`) additionally exposes a per-slot `palm` flag.

### Finger (`PointerDeviceKind.touch`)

| Field | Observed |
|---|---|
| pressure | `1.000` always — one distinct value |
| distance | `0.00` |
| tilt | `0.000` |
| radiusMajor | `0.0 – 3.4` |
| size | `0.024 – 1.000` |

### Pen (`PointerDeviceKind.stylus`)

| Field | Observed |
|---|---|
| pressure | `0.000 – 1.000`, **180 distinct values** |
| distance | `0.00 – 114.00` (hover height) |
| tilt | `0.000 – 0.666` rad |
| buttons | `0`, `1`, `2` |
| radiusMajor | `0.0` |

### Gestures captured

```
#1 kind=touch  n= 38  btns=[0,1]  pressure 1.000-1.000   finger
#3 kind=stylus n= 39  btns=[0,1]  pressure 0.000-1.000   pen, synthetic
#4 kind=touch  n= 17  btns=[0,1]  pressure 1.000-1.000   finger
#5 kind=stylus n=343  btns=[0,1]  pressure 0.000-0.212   pen, real writing
#6 kind=stylus n=116  btns=[2]    pressure 0.000-0.446   pen, side button held
```

Plus **93 hover events**, distance `0.0 – 114.0`, arriving before contact.

### What this establishes

1. **The EMR digitizer reports as a true `stylus`** in Flutter. Discrimination
   by `event.kind` is sound on this hardware — this was the one assumption
   worth verifying, and it holds.
2. **Pressure is real and finely quantised** (180 levels in one session).
   Variable stroke width is achievable.
3. **The side button arrives as `buttons == 2`** (`kPrimaryStylusButton`), and
   it is visible on hover, before contact.
4. **Hover is available** up to distance ~114, so the app can show a cursor or
   pre-arm the eraser before the nib lands.
5. **Finger pressure is a constant 1.0** — pressure cannot distinguish a light
   touch from a firm one on touch input, only pen from finger.

### What was NOT observed

**`PointerDeviceKind.invertedStylus` never appeared.** The flip-to-erase
gesture was performed, but every event came through as `stylus`. Two possible
causes: this S Pen has no inversion sensor, or Samsung routes inversion through
the side button instead. **Do not build flip-to-erase on `invertedStylus`
without re-measuring on the target device.** The side button (`buttons == 2`)
is the verified, available signal.

---

## 3. Design

### 3.1 Pen writes immediately; finger never does

The pen draws whenever the notebook is open, with no mode toggle. A finger
scrolls and drags, and draws only when draw mode is explicitly on (unchanged,
so touch-only devices keep working exactly as now).

This inverts the current early-return: the `drawingEnabled` gate applies to
touch and mouse, not to stylus. `IgnorePointer` must go, replaced by hit-test
behaviour that lets non-stylus pointers fall through to the scroll view.

*Why:* on a pen device, toggling a mode before writing is the single biggest
friction in a handwriting app. The hardware tells us it is a pen; use it.

### 3.2 Palm rejection

With the pen active, touch pointers on the canvas are ignored for drawing while
a stylus is in contact or hovering within the hover threshold. Concretely:
track "pen present" from hover/down events with a short trailing window
(~500 ms after the last stylus event); while pen-present is true, touch does
not draw, does not drag cards, and does not scroll the page.

*Why:* resting a hand while writing produces large touch contacts that would
otherwise scroll the page mid-word. The trailing window covers the gap between
strokes when the nib lifts briefly.

This is a genuine behaviour change for touch and must be gated so it only
engages on devices that have actually produced stylus events — a phone with no
pen must never suppress touch.

### 3.3 Pressure-varying stroke width

`InkStroke` carries a single `width`; `InkPoint` carries only `x`/`y`. To vary
width along a stroke, `InkPoint` gains an optional `p` (pressure, 0–1).

Storage stays backward compatible: `InkPoint.tryFromJson` already tolerates
missing fields, so old notebooks load with `p == null` and render at the
stroke's flat width. New strokes store per-point pressure and render as a
tapered path.

*Why optional:* refusing to break existing notebook files is worth more than
uniform data. Rendering must handle both.

### 3.4 Side button as eraser

While `buttons == kPrimaryStylusButton`, the pen erases instead of drawing —
matching the measured `btns=[2]` gesture, and not requiring the eraser toggle.

Flip-to-erase is **deferred** until `invertedStylus` is observed on real
hardware. Shipping a gesture that silently does nothing is worse than not
shipping it.

### 3.5 Hover cursor

A small ring follows the pen while hovering (distance > 0, no contact),
showing where the nib will land and its current width. Cheap to draw, and it
makes the eraser's reach legible before committing to a swipe.

---

## 4. Phased plan

1. **Characterisation tests** (done) — pin current behaviour.
2. **Stylus draws without draw mode.** Restructure the pointer gate; keep
   finger behaviour identical. *Accepts:* stylus down with `drawingEnabled=false`
   produces a stroke; touch down with `drawingEnabled=false` does not.
3. **Palm rejection.** Pen-present window; suppress touch drawing, card drag
   and scroll while active. *Accepts:* synthetic stylus-down followed by
   touch-move produces no scroll and no stroke from the touch pointer; with no
   prior stylus event, touch scrolls normally.
4. **Pressure width.** Optional `p` on `InkPoint`, tapered rendering, old files
   still load. *Accepts:* a stroke with varying pressure renders varying width;
   a legacy notebook JSON with no `p` loads and renders flat.
5. **Side-button eraser.** *Accepts:* `buttons == 2` erases without the eraser
   toggle; releasing returns to drawing.
6. **Hover cursor.** *Accepts:* hover events position the ring; no ring when no
   stylus has been seen.

Phases 2 and 3 are the ones that change how the app feels. 4–6 are polish and
can ship separately.

---

## 5. Risks

- **Other vendors' pens.** This is measured on one Samsung EMR digitizer.
  Wacom AES, Apple-style actives on other Android tablets, and Chromebook
  styluses may differ. Every rule keys off `PointerDeviceKind`, which is
  Flutter's own abstraction, so the failure mode on an odd device is "pen
  behaves like a finger" — degraded, not broken.
- **Palm rejection suppressing legitimate touch.** Mitigated by engaging only
  after a stylus event has been seen, and by the short trailing window.
- **`radiusMajor` is 0 for the pen** on this device, so palm detection cannot
  use contact size from the Flutter side. The pen-present window is the
  mechanism; Android's own `palm` flag is not exposed to Flutter.

---

## 6. Evidence

Raw probe log (device-specific, kept out of the repo):
`~/Documents/ADH2-device-backups/pen-probe-20260918.log`

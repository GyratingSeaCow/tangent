# Pen colours and highlighter

**Date:** 2026-09-21
**Status:** approved design, not yet implemented
**Scope:** `client/` only. No server, no API, no sync-protocol change.

## Problem

The notebook has one ink: white, uniform. Two nibs (ballpoint, fountain) change
the *shape* of a stroke but never its colour. There is no way to mark a passage
as important, and no way to separate "what I wrote" from "what I need to act
on". On a page of dense handwriting every line has equal weight.

## What we are building

Two additions to the ink model, surfaced through one new gesture:

1. **Pen colours** — white (default), blue, red, amber.
2. **A highlighter tool** — a wide, flat, translucent stroke in yellow
   (default), lime, blue, or pink, painted *beneath* the ink.

Colour is chosen by **long-pressing** a tool in the toolbar, which opens that
tool's palette. Tapping a tool still just selects it.

## Palette

Pen inks (opaque, full stroke width):

| Name  | Value       | Notes                                        |
|-------|-------------|----------------------------------------------|
| White | `#EDF1F3`   | Default. Existing `TangentColors.ink`.        |
| Blue  | `#5AB4FF`   |                                               |
| Red   | `#FF6B6B`   |                                               |
| Amber | `#FFB347`   |                                               |

Highlighter marks (translucent, painted under ink):

| Name   | Value       | Alpha | Notes                                   |
|--------|-------------|-------|-----------------------------------------|
| Yellow | `#FFE14D`   | 0.22  | Default.                                 |
| Lime   | `#D4FF47`   | 0.22  | Same hue as `TangentColors.signal`.      |
| Blue   | `#5AB4FF`   | 0.26  |                                          |
| Pink   | `#FF78DC`   | 0.24  |                                          |

Lime is deliberately retained as a highlighter colour even though it matches
the `signal` accent used for "live or selected". At 22% alpha as a wide band it
reads differently from the 1.5px signal-coloured lasso marquee and the selection
halo. Accepted with eyes open (user decision).

Pen ink is never lime — the existing rule in `tangent_tokens.dart` ("lime ink
competes with the signal accent") still holds for opaque strokes.

## Rendering

### Paint order

`NotebookInkPainter.paint` currently walks `strokes` once, in insertion order,
haloing selected ones. Highlighter strokes must never cover handwriting, so
painting becomes **two passes over the same list**:

1. Pass 1 — every stroke whose tool is highlighter.
2. Pass 2 — every stroke whose tool is pen.

Within each pass, insertion order is preserved, so a later highlight still
covers an earlier one. The active (in-progress) stroke paints last inside its
own pass, so drawing a highlight over existing ink shows the ink staying on top
live, not after lift.

Selection halos keep their current behaviour and are drawn immediately before
their stroke inside whichever pass owns it.

### Highlighter stroke shape

- Width: a fixed multiple (`4x`) of the current pen width, so the size slider
  still governs it and a highlight is unmistakably a band, not a line.
- Cap/join: `StrokeCap.square` / `StrokeJoin.bevel` — a chisel nib, not the
  round cap a pen uses. Distinguishes a highlight from a fat pen stroke.
- **No pressure taper**, regardless of nib. A real highlighter has a flat felt
  tip. `PenStyle` is ignored for highlighter strokes.
- Alpha is baked into the colour constant, not applied per-paint, so the value
  round-trips through JSON unchanged.

Overlapping highlight strokes of the same colour will darken where they cross
(normal alpha compositing). Accepted: it matches how a real marker behaves on
paper and avoids a layer-flattening pass.

## Data model

`InkStroke` gains two optional fields, following the discipline `style`
already established:

```dart
final InkTool tool;    // pen (default) | highlighter
final InkColor colour; // per-tool default when absent
```

Both are **omitted from JSON when they hold the default value**, exactly as
`style` is today:

```dart
if (style != PenStyle.ballpoint) 'style': style.wireValue,
if (tool != InkTool.pen) 'tool': tool.wireValue,
if (colour != InkColor.defaultFor(tool)) 'colour': colour.wireValue,
```

This is the load-bearing rule: **an existing notebook must re-encode
byte-identical.** Every page written before this feature contains neither key
and must continue to contain neither key after a save.

Both readers are tolerant, mirroring `PenStyle.fromWire`: an unknown tool reads
as pen, an unknown colour reads as that tool's default. A device on an older
build opening a newer page shows white pen strokes rather than dropping ink —
the same "show it wrong rather than lose it" stance the codebase already takes.

`copyWith` must carry both fields through. (Note: today's `copyWith` silently
passes `style` without exposing it as a parameter; the new fields follow that
existing shape rather than changing it.)

## Interaction

### Long-press a tool → palette

Long-pressing the **pen** or **highlighter** button opens a small popup
anchored to that button showing its swatches, current one ringed. Tapping a
swatch selects it and closes the popup. Tapping elsewhere dismisses without
changing anything.

Long-press is chosen over a dedicated colour button so the toolbar keeps its
current width — it is already seven controls wide on a phone — and because
the desktop client has just standardised "right-click does what long-press
does", giving this gesture a free desktop equivalent.

### Tool state

The highlighter is a **third mode** alongside pen and eraser, and follows the
rules already written for those:

- Selecting the highlighter clears the eraser and the lasso (mutually
  exclusive gestures, same as today's eraser/lasso rule).
- Tapping the highlighter from outside draw mode **enters draw mode with the
  highlighter active**, per the toolbar contract fixed in `20c8aac`.
- Leaving draw mode resets to pen, extending the existing "a stranded eraser
  would make the next stroke delete work" rule to cover a stranded
  highlighter.

Each tool remembers its own colour for the session. Switching pen → highlighter
→ pen returns to the pen colour you were using.

### Colour affordance

The pen and highlighter icons tint to their selected colour, so the toolbar
answers "what colour am I about to draw in" without opening anything.

## Out of scope

- Per-page or per-notebook default colours.
- A custom colour picker — the palettes are fixed.
- Recolouring existing strokes (select ink, change its colour).
- Highlighting *text blocks*. This is ink-on-canvas only; a highlight drawn
  across a typed block sits under the ink layer and over the page, but knows
  nothing about the text.
- Any PDF-export change. **See risk below.**

## Risks

**PDF export renders ink by rasterising the canvas**, not by vectorising
strokes (`notebook_pdf_exporter.dart`, line 8: "Vectorising the strokes
separately would inevitably…"). Colour and highlighter therefore reach the PDF
for free, with no exporter change — but this must be **verified with a real
exported file**, not assumed, because the exporter builds its own painter
inputs. A test that exports a page containing one highlight and one coloured
pen stroke, and asserts the export succeeds with the strokes present, belongs
in this work.

**Durable-format regression is the expensive failure.** A bug that writes
`"colour":"white"` into every stroke would rewrite every notebook on disk on
the next save, producing a large spurious sync diff across devices. The
byte-identical round-trip test for a legacy page is the gate that catches this
and must exist before the encoder is written.

## Testing

RED first, in this order:

1. **Model** (`test/unit/models/notebook_test.dart`)
   - A legacy stroke (no `tool`, no `colour`) decodes to pen/default and
     **re-encodes byte-identical**.
   - A highlighter stroke round-trips tool and colour.
   - An unknown tool string reads as pen; an unknown colour reads as the
     tool's default; neither drops the stroke.
   - A default-valued stroke omits both keys from its JSON.

2. **Painter** (`test/widget/notebook_ink_canvas_test.dart`)
   - Highlighter strokes paint before pen strokes regardless of insertion
     order.
   - A highlighter stroke paints wider than its nominal width and ignores
     pressure taper.

3. **Toolbar** (`test/widget/notebook_editor_screen_test.dart`)
   - Long-pressing the pen opens the pen palette; picking blue makes the next
     stroke blue.
   - Tapping the highlighter from outside draw mode enters draw mode with the
     highlighter active (extends the `20c8aac` contract).
   - Selecting the highlighter clears the eraser and lasso.
   - Leaving draw mode resets to pen.

4. **Export** (`test/unit/services/notebook_pdf_exporter_test.dart`)
   - A page containing a highlight and a coloured stroke exports successfully.

Full suite (currently 1443) and `flutter analyze` must both be clean, and each
test that encodes a fix gets a sabotage proof, per the project's standard.

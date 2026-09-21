# SPDX-License-Identifier: AGPL-3.0-or-later
"""Render a segmented line's strokes to a greyscale image for OCR.

White background, black polylines at stroke width x scale, 16px margin,
height capped at 384px (TrOCR input norm). Geometry mirrors the Task 0
bake-off renderer that produced the winning transcriptions.
"""

from __future__ import annotations

from PIL import Image, ImageDraw

MARGIN = 16
MAX_HEIGHT = 384
MIN_SIDE = 32


def _stroke_bbox(s: dict) -> tuple[float, float, float, float]:
    xs = [p["x"] for p in s["points"]]
    ys = [p["y"] for p in s["points"]]
    return min(xs), min(ys), max(xs), max(ys)


def render_line(strokes: list[dict], stroke_ids: list[str], scale: float = 2.0) -> Image.Image:
    """Render the strokes named by ``stroke_ids`` onto a fresh canvas.

    ``strokes`` is the full ink stroke list; only members of ``stroke_ids``
    are drawn, and the canvas is sized to their joint bbox. Raises
    ``ValueError`` if any requested id is missing or has no points.
    """
    wanted = set(stroke_ids)
    line = [s for s in strokes if s.get("id") in wanted and s.get("points")]
    found = {s["id"] for s in line}
    if found != wanted:
        raise ValueError(f"stroke ids not found or empty: {sorted(wanted - found)}")

    boxes = [_stroke_bbox(s) for s in line]
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[2] for b in boxes)
    y1 = max(b[3] for b in boxes)

    w = int((x1 - x0) * scale) + 2 * MARGIN
    h = int((y1 - y0) * scale) + 2 * MARGIN
    img = Image.new("L", (max(w, MIN_SIDE), max(h, MIN_SIDE)), 255)
    draw = ImageDraw.Draw(img)
    for s in line:
        pts = [
            (MARGIN + (p["x"] - x0) * scale, MARGIN + (p["y"] - y0) * scale)
            for p in s["points"]
        ]
        lw = max(2, int(s.get("width", 3) * scale))
        if len(pts) == 1:
            x, y = pts[0]
            draw.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=0)
        else:
            draw.line(pts, fill=0, width=lw, joint="curve")

    if img.height > MAX_HEIGHT:
        ratio = MAX_HEIGHT / img.height
        img = img.resize((max(1, int(img.width * ratio)), MAX_HEIGHT))
    return img

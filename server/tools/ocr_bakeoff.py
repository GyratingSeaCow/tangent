# SPDX-License-Identifier: AGPL-3.0-or-later
"""OCR bake-off: render real notebook ink to line images, run TrOCR flavours.

Spike quality (plan Task 0). Usage:
    python ocr_bakeoff.py INK_JSON OUT_DIR [--models base,large] [--device cpu|cuda]

INK_JSON: {"strokes": [{"id","width","tool","points":[{"x","y",...},...]},...]}
Writes OUT_DIR/line-N.png, prints a markdown table of transcriptions + latency.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw


def stroke_bbox(s: dict) -> tuple[float, float, float, float]:
    xs = [p["x"] for p in s["points"]]
    ys = [p["y"] for p in s["points"]]
    return min(xs), min(ys), max(xs), max(ys)


def cluster_lines(strokes: list[dict]) -> list[list[dict]]:
    """Naive line clustering: group strokes by bbox y-CENTRE gaps.

    Bottom-edge tracking fails on handwriting (descenders overlap the next
    line); centres of same-line strokes cluster tightly even when their
    boxes overlap across lines.
    """
    pen = [s for s in strokes if s.get("tool", "pen") == "pen" and s.get("points")]
    if not pen:
        return []
    heights = [stroke_bbox(s)[3] - stroke_bbox(s)[1] for s in pen]
    h = statistics.median([x for x in heights if x > 1] or [20.0])

    def centre(s: dict) -> float:
        b = stroke_bbox(s)
        return (b[1] + b[3]) / 2

    pen.sort(key=centre)
    lines: list[list[dict]] = [[pen[0]]]
    for s in pen[1:]:
        line_centre = statistics.median(centre(t) for t in lines[-1])
        if centre(s) - line_centre > 0.9 * h:
            lines.append([s])
        else:
            lines[-1].append(s)
    return lines


def render_line(line: list[dict], scale: float = 2.0, margin: int = 16) -> Image.Image:
    x0 = min(stroke_bbox(s)[0] for s in line)
    y0 = min(stroke_bbox(s)[1] for s in line)
    x1 = max(stroke_bbox(s)[2] for s in line)
    y1 = max(stroke_bbox(s)[3] for s in line)
    w = int((x1 - x0) * scale) + 2 * margin
    h = int((y1 - y0) * scale) + 2 * margin
    img = Image.new("L", (max(w, 32), max(h, 32)), 255)
    d = ImageDraw.Draw(img)
    for s in line:
        pts = [
            (margin + (p["x"] - x0) * scale, margin + (p["y"] - y0) * scale)
            for p in s["points"]
        ]
        lw = max(2, int(s.get("width", 3) * scale))
        if len(pts) == 1:
            x, y = pts[0]
            d.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=0)
        else:
            d.line(pts, fill=0, width=lw, joint="curve")
    if img.height > 384:
        ratio = 384 / img.height
        img = img.resize((int(img.width * ratio), 384))
    return img


MODELS = {
    "base": "microsoft/trocr-base-handwritten",
    "large": "microsoft/trocr-large-handwritten",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ink_json")
    ap.add_argument("out_dir")
    ap.add_argument("--models", default="base,large")
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    strokes = json.loads(Path(args.ink_json).read_text())["strokes"]
    lines = cluster_lines(strokes)
    print(f"{len(strokes)} strokes -> {len(lines)} lines", file=sys.stderr)
    paths = []
    for i, line in enumerate(lines):
        p = out / f"line-{i}.png"
        render_line(line).convert("RGB").save(p)
        paths.append(p)

    results: dict[str, list[tuple[str, float]]] = {}
    for key in args.models.split(","):
        from transformers import TrOCRProcessor, VisionEncoderDecoderModel
        import torch

        name = MODELS[key]
        print(f"loading {name} on {args.device}...", file=sys.stderr)
        proc = TrOCRProcessor.from_pretrained(name)
        model = VisionEncoderDecoderModel.from_pretrained(name).to(args.device)
        model.eval()
        rows = []
        for p in paths:
            img = Image.open(p).convert("RGB")
            t0 = time.perf_counter()
            with torch.no_grad():
                pixel = proc(images=img, return_tensors="pt").pixel_values.to(args.device)
                ids = model.generate(pixel, max_new_tokens=64)
            text = proc.batch_decode(ids, skip_special_tokens=True)[0]
            rows.append((text, time.perf_counter() - t0))
        results[key] = rows
        del model

    keys = list(results.keys())
    print("| line | " + " | ".join(f"{k} ({args.device})" for k in keys) + " |")
    print("|---|" + "|".join("---" for _ in keys) + "|")
    for i, p in enumerate(paths):
        cells = [f"{results[k][i][0]}  `{results[k][i][1]:.2f}s`" for k in keys]
        print(f"| {p.name} | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# SPDX-License-Identifier: AGPL-3.0-or-later
"""Standalone TrOCR inference script — runs in the on-demand OCR venv.

This file is executed by ``ocr_env.python_path()`` (the venv the installer
built), NEVER imported into the server process: torch and transformers stay
out of the server's memory. It must therefore not import anything from
``app`` — the venv has no access to the server's packages, only to its own
site-packages and this file's absolute path.

Modes:
  --image <path>       OCR one line image; the text goes to stdout.
  --serve              Load the model ONCE, then read one image path per
                       line from stdin and write exactly one JSON result
                       line per input ({"text": ...} or {"error": ...}),
                       flushed immediately. EOF on stdin exits cleanly.
                       This is the worker's persistent-child protocol —
                       one model load per child lifetime, not per line.
  --selftest           Render the word "test" internally, assert the model
                       returns non-empty. The installer's verify step runs
                       this before an install is published.
  --models-dir <path>  Override the weights cache (default: derived from the
                       interpreter's own location, <env>/models).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

MODEL_ID = "microsoft/trocr-base-handwritten"


def default_models_dir(python_path: str | None = None) -> Path:
    """The weights cache for the venv that owns ``python_path``.

    The installer lays the env out as ``<env>/venv/{Scripts,bin}/python`` and
    ``<env>/models``; three levels up from the interpreter is ``<env>``.
    """
    py = Path(python_path if python_path is not None else sys.executable)
    return py.parent.parent.parent / "models"


def _load_model(models_dir: Path):
    """Load processor + model from the local snapshot cache. No network."""
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel

    processor = TrOCRProcessor.from_pretrained(
        MODEL_ID, cache_dir=str(models_dir), local_files_only=True
    )
    model = VisionEncoderDecoderModel.from_pretrained(
        MODEL_ID, cache_dir=str(models_dir), local_files_only=True
    )
    model.eval()
    return processor, model


def _recognize_loaded(processor, model, image) -> str:
    """OCR one PIL image with an already-loaded processor+model pair."""
    import torch

    pixel_values = processor(
        images=image.convert("RGB"), return_tensors="pt"
    ).pixel_values
    with torch.no_grad():
        generated = model.generate(pixel_values, max_new_tokens=64)
    return processor.batch_decode(generated, skip_special_tokens=True)[0].strip()


def recognize(image, models_dir: Path) -> str:
    """OCR one PIL image into a text line (loads the model — single-shot)."""
    processor, model = _load_model(models_dir)
    return _recognize_loaded(processor, model, image)


def serve(models_dir: Path) -> int:
    """Persistent line-protocol server: one image path in, one JSON line out.

    The model is loaded exactly once. Per-line failures (unreadable image,
    model error) are reported as {"error": ...} on stdout — the process
    keeps serving. EOF on stdin is the clean-shutdown signal.
    """
    import json

    from PIL import Image

    # Deterministic cross-platform framing: the parent writes utf-8 paths.
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass  # non-reconfigurable stream (redirected/test harness)

    processor, model = _load_model(models_dir)
    for raw in sys.stdin:
        path = raw.strip()
        if not path:
            continue
        try:
            with Image.open(path) as img:
                text = _recognize_loaded(processor, model, img)
            out = {"text": text}
        except Exception as exc:  # noqa: BLE001 — one bad line must not kill the server
            out = {"error": f"{type(exc).__name__}: {exc}"}
        print(json.dumps(out), flush=True)
    return 0


def _selftest_image():
    """A synthetic handwriting stand-in: the word "test" drawn on white.

    PIL's default bitmap font is ~10px; upscale 4x so the glyph occupies a
    realistic fraction of TrOCR's 384px input norm instead of vanishing.
    """
    from PIL import Image, ImageDraw

    img = Image.new("L", (128, 32), 255)
    draw = ImageDraw.Draw(img)
    draw.text((16, 8), "test", fill=0)
    return img.resize((512, 128), Image.NEAREST)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="TrOCR line inference")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--image", help="path to a line PNG to recognize")
    group.add_argument(
        "--serve",
        action="store_true",
        help="persistent mode: image paths on stdin, JSON results on stdout",
    )
    group.add_argument(
        "--selftest",
        action="store_true",
        help="render a test glyph and assert the model answers non-empty",
    )
    parser.add_argument("--models-dir", default=None)
    args = parser.parse_args(argv)

    models_dir = (
        Path(args.models_dir) if args.models_dir else default_models_dir()
    )

    if args.serve:
        return serve(models_dir)

    if args.selftest:
        text = recognize(_selftest_image(), models_dir)
        if not text:
            print("selftest failed: model returned empty text", file=sys.stderr)
            return 1
        print(text)
        return 0

    from PIL import Image

    text = recognize(Image.open(args.image), models_dir)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

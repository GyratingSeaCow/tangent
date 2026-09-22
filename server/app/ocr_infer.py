# SPDX-License-Identifier: AGPL-3.0-or-later
"""Standalone TrOCR inference script — runs in the on-demand OCR venv.

This file is executed by ``ocr_env.python_path()`` (the venv the installer
built), NEVER imported into the server process: torch and transformers stay
out of the server's memory. It must therefore not import anything from
``app`` — the venv has no access to the server's packages, only to its own
site-packages and this file's absolute path.

Modes:
  --image <path>       OCR one line image; the text goes to stdout.
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


def recognize(image, models_dir: Path) -> str:
    """OCR one PIL image into a text line."""
    import torch

    processor, model = _load_model(models_dir)
    pixel_values = processor(
        images=image.convert("RGB"), return_tensors="pt"
    ).pixel_values
    with torch.no_grad():
        generated = model.generate(pixel_values, max_new_tokens=64)
    return processor.batch_decode(generated, skip_special_tokens=True)[0].strip()


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
        "--selftest",
        action="store_true",
        help="render a test glyph and assert the model answers non-empty",
    )
    parser.add_argument("--models-dir", default=None)
    args = parser.parse_args(argv)

    models_dir = (
        Path(args.models_dir) if args.models_dir else default_models_dir()
    )

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

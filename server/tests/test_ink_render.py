# SPDX-License-Identifier: AGPL-3.0-or-later
"""Line rendering: strokes -> greyscale PIL image for the OCR worker."""

from __future__ import annotations

from app.services.ink_render import render_line


def _stroke(sid: str, points: list[tuple[float, float]], *, tool: str = "pen",
            width: float = 3.0) -> dict:
    return {
        "id": sid,
        "width": width,
        "tool": tool,
        "points": [{"x": float(x), "y": float(y)} for x, y in points],
    }


STROKES = [
    _stroke("a", [(0, 0), (30, 40), (15, 20)]),
    _stroke("b", [(40, 0), (70, 40)]),
    _stroke("far", [(0, 500), (30, 540)]),
]


def test_render_mode_and_white_corners():
    img = render_line(STROKES, ["a", "b"])
    assert img.mode == "L"
    w, h = img.size
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        assert img.getpixel(corner) == 255


def test_render_has_ink_within_bbox():
    img = render_line(STROKES, ["a", "b"])
    # 16px margin + strokes at scale 2: ink must appear, and only inside
    # the margin-framed content box.
    pixels = img.load()
    w, h = img.size
    ink = [(x, y) for x in range(w) for y in range(h) if pixels[x, y] < 128]
    assert ink, "rendered image contains no ink pixels"
    for x, y in ink:
        assert 16 - 4 <= x <= w - 16 + 4
        assert 16 - 4 <= y <= h - 16 + 4


def test_render_only_selected_strokes():
    """The 'far' stroke is not in stroke_ids: canvas sized to a+b only."""
    img = render_line(STROKES, ["a", "b"])
    # a+b span 70x40 -> 140x80 at scale 2, +32 margin = 172x112.
    assert img.size == (172, 112)


def test_render_height_cap_384():
    tall = [_stroke("t", [(0, 0), (10, 1000)])]
    img = render_line(tall, ["t"])
    assert img.height <= 384
    assert img.mode == "L"
    # Aspect ratio must survive the cap: pre-cap canvas is
    # int(10*2)+32 = 52 wide by int(1000*2)+32 = 2032 high, so the capped
    # width must be ~ 52 * (384/2032). A width-preserving squash would
    # leave width at 52 and hand TrOCR a distorted line image.
    pre_w, pre_h = 52, 2032
    assert img.height == 384
    assert abs(img.width - pre_w * 384 / pre_h) <= 1


def test_render_scale_parameter():
    img1 = render_line(STROKES, ["a", "b"], scale=1.0)
    img2 = render_line(STROKES, ["a", "b"], scale=2.0)
    assert img2.width > img1.width
    assert img2.height > img1.height


def test_render_single_point_stroke_draws_dot():
    dot = [_stroke("dot", [(5.0, 5.0)])]
    img = render_line(dot, ["dot"])
    w, h = img.size
    pixels = img.load()
    ink = [(x, y) for x in range(w) for y in range(h) if pixels[x, y] < 128]
    assert ink, "single-point stroke rendered no ink"


def test_render_unknown_ids_raise():
    import pytest

    with pytest.raises(ValueError):
        render_line(STROKES, ["nope"])

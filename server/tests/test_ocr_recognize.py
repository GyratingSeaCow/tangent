# SPDX-License-Identifier: AGPL-3.0-or-later
"""Endpoint-level contract tests for POST /v1/ocr/recognize."""

from __future__ import annotations

import itertools

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.services import ocr_env, ocr_worker


def _stroke(sid: str, x: float, y: float) -> dict:
    return {
        "id": sid,
        "width": 3,
        "points": [
            {"x": x, "y": y},
            {"x": x + 30, "y": y + 20},
        ],
    }


@pytest.fixture
def api(temp_data_dir, monkeypatch):
    monkeypatch.setattr(ocr_env, "python_path", lambda: "fake-python")
    with TestClient(create_app()) as client:
        token = client.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield client, {"Authorization": f"Bearer {token}"}


def test_recognize_requires_auth(api):
    client, _ = api
    assert client.post("/v1/ocr/recognize", json={"strokes": []}).status_code == 401


def test_recognize_returns_409_with_existing_not_installed_detail(api, monkeypatch):
    client, auth = api
    monkeypatch.setattr(ocr_env, "python_path", lambda: None)

    response = client.post("/v1/ocr/recognize", json={"strokes": []}, headers=auth)

    assert response.status_code == 409
    assert response.json() == {"detail": "OCR environment is not installed"}


def test_recognize_shuffled_strokes_returns_lines_in_reading_order(
    api, monkeypatch
):
    client, auth = api
    # Deliberately bottom/right first. The endpoint must preserve segment_ink's
    # geometry-derived top-to-bottom order, not request or stroke-id order.
    strokes = [
        _stroke("bottom-right", 80, 80),
        _stroke("top-right", 80, 0),
        _stroke("bottom-left", 0, 80),
        _stroke("top-left", 0, 0),
    ]
    texts = iter(["top line", "bottom line"])
    monkeypatch.setattr(ocr_worker, "run_inference", lambda image: next(texts))

    response = client.post(
        "/v1/ocr/recognize", json={"strokes": strokes}, headers=auth
    )

    assert response.status_code == 200
    assert response.json() == {
        "lines": [
            {
                "text": "top line",
                "stroke_ids": ["top-left", "top-right"],
                "bbox": [0.0, 0.0, 110.0, 20.0],
            },
            {
                "text": "bottom line",
                "stroke_ids": ["bottom-left", "bottom-right"],
                "bbox": [0.0, 80.0, 110.0, 100.0],
            },
        ]
    }


def test_recognize_renders_each_line_at_scale_two(api, monkeypatch):
    client, auth = api
    calls = []

    def fake_render(strokes, stroke_ids, scale):
        calls.append((stroke_ids, scale))
        return object()

    monkeypatch.setattr("app.api.ocr.ink_render.render_line", fake_render)
    monkeypatch.setattr(ocr_worker, "run_inference", lambda image: "text")

    response = client.post(
        "/v1/ocr/recognize",
        json={"strokes": [_stroke("one", 0, 0)]},
        headers=auth,
    )

    assert response.status_code == 200
    assert calls == [(["one"], 2.0)]


def test_recognize_drops_blank_lines_and_all_blank_is_empty(api, monkeypatch):
    client, auth = api
    answers = itertools.chain(["  ", "kept"], itertools.repeat("\n"))
    monkeypatch.setattr(ocr_worker, "run_inference", lambda image: next(answers))
    two_lines = [_stroke("top", 0, 0), _stroke("bottom", 0, 80)]

    response = client.post(
        "/v1/ocr/recognize", json={"strokes": two_lines}, headers=auth
    )
    assert [line["text"] for line in response.json()["lines"]] == ["kept"]

    response = client.post(
        "/v1/ocr/recognize", json={"strokes": two_lines}, headers=auth
    )
    assert response.status_code == 200
    assert response.json() == {"lines": []}


def test_recognize_inference_failure_is_502_not_empty(api, monkeypatch):
    client, auth = api

    def fail(_image):
        raise RuntimeError("child died")

    monkeypatch.setattr(ocr_worker, "run_inference", fail)
    response = client.post(
        "/v1/ocr/recognize",
        json={"strokes": [_stroke("one", 0, 0)]},
        headers=auth,
    )

    assert response.status_code == 502
    assert response.json() == {"detail": "handwriting recognition failed"}


@pytest.mark.parametrize(
    "body",
    [
        {"strokes": "not-a-list"},
        {"strokes": [{"id": "empty", "width": 3, "points": []}]},
        {"strokes": [{"id": "missing-points", "width": 3}]},
    ],
)
def test_recognize_rejects_malformed_strokes(api, body):
    client, auth = api
    assert client.post("/v1/ocr/recognize", json=body, headers=auth).status_code == 422
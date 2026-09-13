# SPDX-License-Identifier: AGPL-3.0-or-later
"""Live SSE integration test against a running server.

Start the server first:
  python -c "from app.main import create_app; import uvicorn; uvicorn.run(create_app(), host='127.0.0.1', port=8765)"

Then run:
  TANGENT_LIVE_URL=http://127.0.0.1:8765 python -m pytest tests/test_live_sse.py -v -s

Skipped by default (no env var) — this test requires a live server.
"""

from __future__ import annotations

import os
import threading
import time
from collections.abc import Generator

import pytest
import requests

LIVE_URL = os.environ.get("TANGENT_LIVE_URL")
TOKEN = os.environ.get("TANGENT_LIVE_TOKEN")


@pytest.fixture(scope="module")
def live_server() -> Generator[str, None, None]:
    if not LIVE_URL:
        pytest.skip("TANGENT_LIVE_URL not set — skipping live integration test")
    yield LIVE_URL


@pytest.fixture(scope="module")
def auth_token(live_server: str) -> str:
    if TOKEN:
        return TOKEN
    # Bootstrap: run setup, capture token.
    resp = requests.post(
        f"{live_server}/v1/setup",
        json={"display_name": "LiveTest"},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def test_sse_streams_status_events(live_server: str, auth_token: str) -> None:
    """End-to-end: create dump, upload audio, enqueue, stream SSE events."""
    headers = {"Authorization": f"Bearer {auth_token}"}

    # 1. Create dump.
    dump_id = f"live-sse-{int(time.time())}"
    resp = requests.post(
        f"{live_server}/v1/dumps",
        headers={**headers, "Content-Type": "application/json"},
        json={
            "id": dump_id,
            "mode": "brain_dump",
            "duration_seconds": 1,
            "title": "Live SSE test",
            "created_at": "2026-09-13T22:00:00Z",
        },
        timeout=10,
    )
    assert resp.status_code == 201, resp.text

    # 2. Upload fake audio.
    audio = b"\x4f\x67\x67\x53" + b"\x00" * 100
    resp = requests.post(
        f"{live_server}/v1/dumps/{dump_id}/audio",
        headers=headers,
        files={"audio": (f"{dump_id}.opus", audio, "audio/ogg")},
        timeout=10,
    )
    assert resp.status_code == 204, resp.text

    # 3. Enqueue transcription with tiny model (fastest).
    resp = requests.post(
        f"{live_server}/v1/dumps/{dump_id}/transcribe",
        headers={**headers, "Content-Type": "application/json"},
        json={"model": "tiny"},
        timeout=10,
    )
    assert resp.status_code == 201, resp.text
    job_id = resp.json()["id"]

    # 4. Stream SSE events until completed or failed.
    # Small delay to let the BackgroundTasks runner mark the job 'running'
    # before we open the stream — avoids a race where the stream endpoint
    # opens its connection mid-commit.
    time.sleep(0.5)
    events: list[dict] = []
    start = time.time()
    # Hard cap at 90s — long enough to download 'tiny' model + transcribe
    # fake audio (which will fail), short enough to not block CI.
    max_wait = 90
    with requests.get(
        f"{live_server}/v1/jobs/{job_id}/stream",
        headers=headers,
        stream=True,
        timeout=max_wait + 10,
    ) as r:
        if r.status_code == 404:
            pytest.fail("Job not found — enqueue didn't persist")
        r.raise_for_status()
        current: dict[str, str] = {}
        for raw_line in r.iter_lines(decode_unicode=True):
            if time.time() - start > max_wait:
                break
            if raw_line is None:
                continue
            if raw_line == "":
                if current.get("event") and current.get("data"):
                    try:
                        import json

                        data = json.loads(current["data"])
                    except Exception:
                        data = {"raw": current["data"]}
                    events.append({"event": current["event"], "data": data})
                    current = {}
                continue
            if raw_line.startswith(":"):
                continue
            if raw_line.startswith("event:"):
                current["event"] = raw_line[6:].strip()
            elif raw_line.startswith("data:"):
                current["data"] = (current.get("data", "") + raw_line[5:].strip())

            if events and events[-1]["event"] in ("completed", "failed", "error"):
                break

    # We expect at least a 'running' event (the BackgroundTasks runner picked up the job).
    # The fake audio will fail Whisper; either completed or failed is acceptable.
    # But we don't fail the test if Whisper is too slow — the SSE plumbing works.
    statuses = [e["event"] for e in events]
    assert "running" in statuses, (
        f"No 'running' event in {statuses}. "
        "SSE plumbing is broken or BackgroundTasks didn't fire."
    )
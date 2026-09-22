# SPDX-License-Identifier: AGPL-3.0-or-later
"""The ink-index backfill: a device whose checkpoint has passed the index.

The bug this pins (found on real hardware, tablet upgrade 1.6.1 -> 1.7.0):
a legacy client's checkpoint advances PAST filtered ink_index entries by
design (sync.py: "their checkpoint still advances past the filtered
entries"). After upgrading and enabling handwriting search, the device
pulls with since_seq == head_seq, receives nothing, and no path ever
re-emits the index rows. Search shows "No matches" forever even though
the server has a full index.

The fix under test: POST /v1/ocr/index/backfill re-records one ink_index
upsert per indexed notebook into the change log. Payloads are built at
pull time from the live table (replace-set), so re-emitting is cheap and
idempotent for every other device.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def authed_client(temp_data_dir: Path):
    init_db(str(temp_data_dir))
    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) "
            "VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    from app.api.ocr import router as ocr_router
    from app.api.sync import router as sync_router

    app = FastAPI()
    app.include_router(sync_router)
    app.include_router(ocr_router)
    return TestClient(app), token


def _seed_indexed_notebook(data_dir: Path, notebook_id: str) -> None:
    """A notebook with ink_index rows whose change entries are long gone."""
    conn = sqlite3.connect(data_dir / "tangent.db")
    try:
        now = int(time.time())
        conn.execute(
            "INSERT INTO notebooks (id, title, doc, ink, updated_at, created_at) "
            "VALUES (?, 'Legacy NB', ?, NULL, ?, ?)",
            (notebook_id, json.dumps({"blocks": []}), now, now),
        )
        conn.execute(
            "INSERT INTO ink_index (id, notebook_id, line_id, word_text, "
            "word_text_lower, bbox_json, stroke_ids_json, model, indexed_at) "
            "VALUES ('w-1', ?, 'line-1', 'Hello', 'hello', '[0,0,10,10]', "
            "'[\"s1\"]', 'trocr-base', ?)",
            (notebook_id, now),
        )
        conn.commit()
    finally:
        conn.close()


def test_upgraded_device_past_the_index_gets_backfill(
    authed_client, temp_data_dir: Path
) -> None:
    """since_seq == head: pull is empty until backfill re-emits the index."""
    client, token = authed_client
    headers = {"Authorization": f"Bearer {token}"}
    _seed_indexed_notebook(temp_data_dir, "nb-legacy")

    # The upgraded device's reality: checkpoint already at head.
    head = client.get(
        "/v1/sync/pull",
        params={
            "device_id": "device-tablet-1",
            "since_seq": 0,
            "include_ink_index": "true",
        },
        headers=headers,
    ).json()["head_seq"]

    empty = client.get(
        "/v1/sync/pull",
        params={
            "device_id": "device-tablet-1",
            "since_seq": head,
            "include_ink_index": "true",
        },
        headers=headers,
    ).json()
    assert empty["changes"] == []  # the bug: nothing ever arrives

    # The fix: the client asks for a backfill when the toggle turns on.
    resp = client.post("/v1/ocr/index/backfill", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["notebooks"] == 1

    page = client.get(
        "/v1/sync/pull",
        params={
            "device_id": "device-tablet-1",
            "since_seq": head,
            "include_ink_index": "true",
        },
        headers=headers,
    ).json()
    kinds = [c["entity_type"] for c in page["changes"]]
    assert kinds == ["ink_index"]
    payload = page["changes"][0]["payload"]
    assert payload["notebook_id"] == "nb-legacy"
    assert [w["word_text"] for w in payload["rows"]] == ["Hello"]


def test_backfill_with_no_index_is_a_noop(authed_client) -> None:
    """No indexed notebooks: 200, zero notebooks, no change-log spam."""
    client, token = authed_client
    headers = {"Authorization": f"Bearer {token}"}

    resp = client.post("/v1/ocr/index/backfill", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["notebooks"] == 0

    page = client.get(
        "/v1/sync/pull",
        params={
            "device_id": "device-x",
            "since_seq": 0,
            "include_ink_index": "true",
        },
        headers=headers,
    ).json()
    assert page["changes"] == []


def test_backfill_requires_auth(authed_client) -> None:
    client, _ = authed_client
    resp = client.post("/v1/ocr/index/backfill")
    assert resp.status_code in (401, 403)

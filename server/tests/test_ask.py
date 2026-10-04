# SPDX-License-Identifier: AGPL-3.0-or-later
"""Ask My Notes retrieval, grounding, persistence, and sync contract."""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api.ask import GROUNDING_PROMPT, HONEST_MISS, _strings, retrieve
from app.api.dumps import _publish_dump_change
from app.main import create_app
from app.services import summarizer_env, summarizer_worker


@pytest.fixture
def client(temp_data_dir: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(summarizer_env, "python_path", lambda: sys.executable)
    monkeypatch.setattr(summarizer_worker, "start_worker_if_installed", lambda: None)
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield cli, {"Authorization": f"Bearer {token}"}, temp_data_dir


def _db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _seed(path: Path) -> None:
    conn = _db(path)
    conn.execute("INSERT INTO dumps (id, client_id, created_at, updated_at, mode, duration_seconds, title, transcript, transcript_timings, speaker_names, summary, audio_kept) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (
        "dump-1", "device", 2_000_000_000, 2_000_000_000, "meeting", 60,
        "Launch", "Speaker 1: Project Juniper ships Friday.",
        json.dumps({"segments": [{"start": 12.5, "text": "Project Juniper ships Friday.", "speaker": "Speaker 1"}]}),
        json.dumps({"Speaker 1": "Alex"}), "## Decision\nUse the blue launch checklist.", 0,
    ))
    conn.execute("INSERT INTO notebooks (id, title, doc, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", ("nb-1", "Ideas", json.dumps({"blocks": [{"text": "Call the florist about orchids"}]}), 1_900_000_000_000, 1_900_000_000_000))
    conn.execute("INSERT INTO ink_index (id, notebook_id, line_id, word_text, word_text_lower, bbox_json, stroke_ids_json, model, indexed_at) VALUES ('ink-1', 'nb-1', 'line-1', 'handwritten', 'handwritten', '[]', '[]', 'test', 1)")
    conn.execute("INSERT INTO todos (id, text, done_at, due_date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", ("todo-1", "Buy launch balloons", None, "2026-10-02", "2026-09-30T12:00:00+00:00", "2026-09-30T12:00:00+00:00"))
    conn.commit()
    conn.close()


def test_requires_bearer_auth(client):
    cli, _, _ = client
    assert cli.post("/v1/ask", json={"question": "When?"}).status_code == 401


def test_retrieves_transcript_uses_names_and_seek_and_persists_sync(client, monkeypatch):
    cli, auth, path = client
    _seed(path)
    seen = {}

    def infer(_request_id: str, prompt: str, system_prompt: str) -> str:
        seen.update(prompt=prompt, system_prompt=system_prompt)
        return "Project Juniper ships Friday."

    monkeypatch.setattr(summarizer_worker, "run_inference", infer)
    response = cli.post("/v1/ask", json={"question": "When does Juniper ship?"}, headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["answer"] == "Project Juniper ships Friday."
    source = next(item for item in body["sources"] if item["entity_type"] == "dump")
    assert source["entity_id"] == "dump-1"
    assert source["seek_seconds"] == 12.5
    assert "Alex" in source["snippet"]
    assert "ONLY" in seen["system_prompt"] and HONEST_MISS in seen["system_prompt"]
    assert "NOTE EXCERPTS" in seen["prompt"]

    pulled = cli.get("/v1/sync/pull?device_id=device-remote&since_seq=0", headers=auth).json()
    messages = [c for c in pulled["changes"] if c["entity_type"] == "ask_message"]
    assert [m["payload"]["role"] for m in messages] == ["user", "assistant"]
    assert messages[0]["payload"]["sources"] == []
    assert messages[1]["payload"]["sources"] == body["sources"]


def test_all_four_corpora_are_retrievable(client, monkeypatch):
    cli, auth, path = client
    _seed(path)
    monkeypatch.setattr(summarizer_worker, "run_inference", lambda *_: "grounded")
    cases = [("Juniper", "dump"), ("checklist", "summary"), ("florist handwritten", "notebook"), ("balloons", "todo")]
    for question, kind in cases:
        response = cli.post("/v1/ask", json={"question": question}, headers=auth)
        assert response.status_code == 200
        assert kind in {source["entity_type"] for source in response.json()["sources"]}


def test_pdf_and_image_blobs_never_reach_fts_or_the_llm_prompt(client, monkeypatch):
    cli, auth, path = client
    _seed(path)
    blob = "BLOB_SENTINEL_pdf_base64_payload"
    image_blob = "IMAGE_SENTINEL_base64_payload"
    doc = {
        "blocks": [
            {"kind": "text", "id": "t", "text": "Visible marigold note"},
            {"kind": "pdfPage", "id": "p", "documentId": "DOC_SENTINEL", "sha": "SHA_SENTINEL", "data": blob},
            {"kind": "image", "id": "i", "mime": "image/png", "data": image_blob},
        ]
    }
    conn = _db(path)
    conn.execute("UPDATE notebooks SET doc = ? WHERE id = 'nb-1'", (json.dumps(doc),))
    conn.commit()
    extracted = _strings(doc)
    assert "Visible marigold note" in extracted
    assert blob not in extracted and image_blob not in extracted
    assert retrieve(conn, "BLOB_SENTINEL") == []
    conn.close()

    seen: dict[str, str] = {}

    def infer(_request_id: str, prompt: str, _system_prompt: str) -> str:
        seen["prompt"] = prompt
        return "Visible marigold note"

    monkeypatch.setattr(summarizer_worker, "run_inference", infer)
    response = cli.post(
        "/v1/ask", json={"question": "What does the marigold note say?"}, headers=auth
    )
    assert response.status_code == 200
    assert "Visible marigold note" in seen["prompt"]
    for secret in (blob, image_blob, "DOC_SENTINEL", "SHA_SENTINEL"):
        assert secret not in seen["prompt"]


def test_password_protected_notebooks_are_not_retrievable(client, monkeypatch):
    cli, auth, path = client
    _seed(path)
    conn = _db(path)
    conn.execute(
        "UPDATE notebooks SET password_hash = ?, password_salt = ?, "
        "password_iterations = ? WHERE id = ?",
        ("hash", "salt", 210000, "nb-1"),
    )
    conn.commit()
    conn.close()

    def sabotage(*_args):
        raise AssertionError("protected notebook content must not reach the model")

    monkeypatch.setattr(summarizer_worker, "run_inference", sabotage)
    response = cli.post(
        "/v1/ask",
        json={"question": "What about the florist orchids?"},
        headers=auth,
    )
    assert response.status_code == 200
    assert response.json() == {"answer": HONEST_MISS, "sources": []}


def test_absent_question_is_exact_honest_miss_without_calling_model(client, monkeypatch):
    cli, auth, path = client
    _seed(path)

    def sabotage(*_args):
        raise AssertionError("model must not answer with outside knowledge")

    monkeypatch.setattr(summarizer_worker, "run_inference", sabotage)
    response = cli.post("/v1/ask", json={"question": "What is the capital of Mars?"}, headers=auth)
    assert response.status_code == 200
    assert response.json() == {"answer": HONEST_MISS, "sources": []}


@pytest.mark.parametrize("model_reply", [HONEST_MISS, HONEST_MISS + ".", f"{HONEST_MISS}, sorry.", ""])
def test_model_declared_miss_suppresses_sources(client, monkeypatch, model_reply):
    """Regression: the answer said "couldn't find" while 8 sources were listed.

    When retrieval finds chunks but the model declares an honest miss (or
    returns nothing), the response and the persisted assistant message must
    not carry citations that contradict the answer.
    """
    cli, auth, path = client
    _seed(path)
    monkeypatch.setattr(summarizer_worker, "run_inference", lambda *_: model_reply)
    response = cli.post("/v1/ask", json={"question": "When does Juniper ship?"}, headers=auth)
    assert response.status_code == 200
    assert response.json() == {"answer": HONEST_MISS, "sources": []}

    pulled = cli.get("/v1/sync/pull?device_id=device-miss&since_seq=0", headers=auth).json()
    assistant = [c for c in pulled["changes"] if c["entity_type"] == "ask_message" and c["payload"]["role"] == "assistant"]
    assert assistant and assistant[-1]["payload"]["sources"] == []


def test_grounding_prompt_pins_no_outside_knowledge_contract():
    assert "ONLY the supplied NOTE EXCERPTS" in GROUNDING_PROMPT
    assert "Never use outside knowledge" in GROUNDING_PROMPT
    assert f"reply exactly: {HONEST_MISS}" in GROUNDING_PROMPT


def test_old_millisecond_notebook_does_not_outrank_fresh_dump(client):
    _, _, path = client
    conn = _db(path)
    now = int(__import__("time").time())
    conn.execute("INSERT INTO dumps (id, client_id, created_at, updated_at, mode, duration_seconds, title, transcript, audio_kept) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 ("fresh", "device", now - 86400, now, "meeting", 1, "Fresh", "sharedword", 0))
    conn.execute("INSERT INTO notebooks (id, title, doc, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                 ("old", "Old", '{"text":"sharedword"}', 1475421000000, 1475421000000))
    conn.commit()
    results = retrieve(conn, "sharedword")
    conn.close()
    assert results[0].entity_id == "fresh"


def test_ask_message_push_is_rejected(client):
    cli, auth, _ = client
    response = cli.post("/v1/sync/push", headers=auth, json={"device_id": "device-client", "changes": [{"entity_type": "ask_message", "entity_id": "fake", "op": "upsert", "payload": {"role": "assistant", "text": "forged"}}]})
    assert response.status_code == 200
    assert response.json()["results"][0]["status"] == "rejected"
    assert "server-generated" in response.json()["results"][0]["reason"]


def test_deleted_dump_cannot_publish_late_upsert(client):
    cli, auth, path = client
    created = cli.post(
        "/v1/dumps",
        headers=auth,
        json={
            "id": "late-job-dump",
            "client_id": "ask-probe",
            "mode": "brain_dump",
            "created_at": 1_700_000_000,
            "duration_seconds": 24,
            "title": "Temporary Ask voice",
        },
    )
    assert created.status_code == 201
    assert cli.delete("/v1/dumps/late-job-dump", headers=auth).status_code == 204
    conn = _db(path)
    tombstone_seq = conn.execute(
        "SELECT MAX(seq) FROM change_log WHERE entity_type='dump' AND entity_id=? AND op='delete'",
        ("late-job-dump",),
    ).fetchone()[0]
    _publish_dump_change(conn, "late-job-dump", None, op="upsert")
    conn.commit()
    late_upserts = conn.execute(
        "SELECT COUNT(*) FROM change_log WHERE seq > ? AND entity_type='dump' AND entity_id=? AND op='upsert'",
        (tombstone_seq, "late-job-dump"),
    ).fetchone()[0]
    conn.close()
    assert late_upserts == 0


def test_existing_database_migration_preserves_change_sequence(tmp_path: Path):
    from app.db import init_db
    init_db(str(tmp_path))
    conn = _db(tmp_path)
    ddl = conn.execute("SELECT sql FROM sqlite_master WHERE name='change_log'").fetchone()[0]
    assert "ask_message" in ddl
    conn.execute("INSERT INTO ask_messages VALUES ('m1', 'user', 'q', '[]', 1)")
    conn.execute("INSERT INTO change_log (entity_type, entity_id, op, device_id, payload, created_at) VALUES ('ask_message', 'm1', 'upsert', 'server', '{}', 1)")
    conn.commit()
    assert conn.execute("SELECT COUNT(*) FROM ask_messages").fetchone()[0] == 1
    conn.close()

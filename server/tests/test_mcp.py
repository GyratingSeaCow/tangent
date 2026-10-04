# SPDX-License-Identifier: AGPL-3.0-or-later
"""Remote MCP server: transport mounting, auth, and the curated tool surface.

Stateless streamable-HTTP with JSON responses means every request is one
plain JSON-RPC POST — no handshake, no session header — which keeps these
tests at the same altitude as the rest of the API suite.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

MCP_HEADERS_BASE = {
    "Accept": "application/json, text/event-stream",
    "Content-Type": "application/json",
}


@pytest.fixture
def client(temp_data_dir: Path):
    with TestClient(create_app()) as cli:
        token = cli.post("/v1/setup", json={"display_name": "T"}).json()["token"]
        yield cli, token, temp_data_dir


def _db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path / "tangent.db")
    conn.row_factory = sqlite3.Row
    return conn


def _seed(path: Path) -> None:
    conn = _db(path)
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, duration_seconds,"
        " title, transcript, speaker_names, summary, audio_kept)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "dump-1", "device", 2_000_000_000, 2_000_000_000, "meeting", 60,
            "Launch", "## Speaker 1\nProject Juniper ships Friday.",
            json.dumps({"Speaker 1": "Alex"}), "## Decision\nBlue checklist.", 0,
        ),
    )
    conn.execute(
        "INSERT INTO dumps (id, client_id, created_at, updated_at, mode, duration_seconds,"
        " title, transcript, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("dump-gone", "device", 2_000_000_100, 2_000_000_100, "brain_dump", 5,
         "Deleted", "Secret zeppelin plans", 2_000_000_200),
    )
    conn.execute(
        "INSERT INTO notebooks (id, title, doc, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        ("nb-1", "Ideas", json.dumps({"blocks": [{"text": "Call the florist about orchids"}]}),
         1_900_000_000, 1_900_000_000),
    )
    conn.execute(
        "INSERT INTO ink_index (id, notebook_id, line_id, word_text, word_text_lower,"
        " bbox_json, stroke_ids_json, model, indexed_at)"
        " VALUES ('ink-1', 'nb-1', 'line-1', 'Zeppelin', 'zeppelin', '[]', '[]', 'test', 1)",
    )
    conn.execute(
        "INSERT INTO todos (id, text, done_at, due_date, created_at, updated_at)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        ("todo-1", "Buy launch balloons", None, "2026-10-02",
         "2026-09-30T12:00:00+00:00", "2026-09-30T12:00:00+00:00"),
    )
    conn.execute(
        "INSERT INTO todos (id, text, done_at, due_date, created_at, updated_at)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        ("todo-done", "Order cake", "2026-09-29T09:00:00+00:00", None,
         "2026-09-28T12:00:00+00:00", "2026-09-29T09:00:00+00:00"),
    )
    conn.commit()
    conn.close()


def _rpc(cli: TestClient, token: str | None, method: str, params: dict | None = None, rpc_id: int = 1):
    headers = dict(MCP_HEADERS_BASE)
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    body: dict = {"jsonrpc": "2.0", "id": rpc_id, "method": method}
    if params is not None:
        body["params"] = params
    return cli.post("/mcp", json=body, headers=headers)


def _call_tool(cli: TestClient, token: str, name: str, arguments: dict | None = None) -> dict:
    response = _rpc(cli, token, "tools/call", {"name": name, "arguments": arguments or {}})
    assert response.status_code == 200, response.text
    result = response.json()["result"]
    assert not result.get("isError"), result
    return json.loads(result["content"][0]["text"])


# --- auth -----------------------------------------------------------------


def test_mcp_requires_auth(client):
    cli, _token, _path = client
    response = _rpc(cli, None, "tools/list")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_mcp_rejects_bad_token(client):
    cli, _token, _path = client
    assert _rpc(cli, "not-the-token", "tools/list").status_code == 401


def test_mcp_bare_mount_path_answers_without_redirect(client):
    """curl and several MCP clients do not re-POST a body across a 307;
    the bare /mcp path must answer directly."""
    cli, token, _path = client
    headers = {**MCP_HEADERS_BASE, "Authorization": f"Bearer {token}"}
    response = cli.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        headers=headers,
        follow_redirects=False,
    )
    assert response.status_code == 200


def test_mcp_accepts_device_token(client):
    cli, _token, path = client
    conn = _db(path)
    from app.auth import hash_token

    conn.execute(
        "INSERT INTO device_tokens (device_id, token_hash, display_name, created_at)"
        " VALUES ('dev-1', ?, 'Phone', 1)",
        (hash_token("device-secret"),),
    )
    conn.commit()
    conn.close()
    assert _rpc(cli, "device-secret", "tools/list").status_code == 200


def test_mcp_rejects_revoked_device_token(client):
    cli, _token, path = client
    conn = _db(path)
    from app.auth import hash_token

    conn.execute(
        "INSERT INTO device_tokens (device_id, token_hash, display_name, created_at, revoked_at)"
        " VALUES ('dev-2', ?, 'Old phone', 1, 2)",
        (hash_token("revoked-secret"),),
    )
    conn.commit()
    conn.close()
    assert _rpc(cli, "revoked-secret", "tools/list").status_code == 401


# --- tool surface ---------------------------------------------------------


def test_tools_list_names(client):
    cli, token, _path = client
    response = _rpc(cli, token, "tools/list")
    assert response.status_code == 200, response.text
    names = {tool["name"] for tool in response.json()["result"]["tools"]}
    assert names == {
        "search_notes",
        "list_recordings",
        "get_recording",
        "list_notebooks",
        "get_notebook",
        "list_todos",
        "create_text_note",
        "create_todo",
    }


def test_search_notes_finds_transcript_and_renders_names(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "search_notes", {"query": "When does Juniper ship?"})
    hits = payload["results"]
    assert any(h["entity_type"] == "dump" and h["entity_id"] == "dump-1" for h in hits)
    dump_hit = next(h for h in hits if h["entity_id"] == "dump-1")
    assert "Alex" in dump_hit["snippet"]  # speaker map applied, raw label not shown


def test_search_notes_never_sees_deleted(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "search_notes", {"query": "zeppelin"})
    # dump-gone is deleted; the only zeppelin left is notebook ink.
    types = {h["entity_type"] for h in payload["results"]}
    ids = {h["entity_id"] for h in payload["results"]}
    assert "dump-gone" not in ids
    assert types == {"notebook"}


def test_search_notes_excludes_password_protected_notebooks(client):
    cli, token, path = client
    _seed(path)
    conn = _db(path)
    conn.execute(
        "UPDATE notebooks SET password_hash='hash', password_salt='salt', "
        "password_iterations=210000 WHERE id='nb-1'"
    )
    conn.commit()
    conn.close()

    payload = _call_tool(cli, token, "search_notes", {"query": "florist orchids"})
    assert all(hit["entity_id"] != "nb-1" for hit in payload["results"])


def test_list_recordings_excludes_deleted_and_flags(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "list_recordings", {})
    recordings = payload["recordings"]
    assert [r["id"] for r in recordings] == ["dump-1"]
    assert recordings[0]["mode"] == "meeting"
    assert recordings[0]["has_transcript"] is True
    assert recordings[0]["has_summary"] is True
    assert payload["total"] == 1


def test_list_recordings_mode_filter(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "list_recordings", {"mode": "brain_dump"})
    assert payload["recordings"] == []


def test_get_recording_renders_speaker_names(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "get_recording", {"recording_id": "dump-1"})
    assert payload["title"] == "Launch"
    assert "## Alex" in payload["transcript"]
    assert "Speaker 1" not in payload["transcript"]
    assert payload["summary"].startswith("## Decision")


def test_get_recording_missing_is_tool_error(client):
    cli, token, path = client
    _seed(path)
    response = _rpc(cli, token, "tools/call", {"name": "get_recording", "arguments": {"recording_id": "nope"}})
    assert response.status_code == 200
    assert response.json()["result"]["isError"] is True


def test_get_notebook_includes_typed_text_and_ink_words(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "get_notebook", {"notebook_id": "nb-1"})
    assert payload["title"] == "Ideas"
    assert "florist" in payload["text"]
    assert payload["handwriting_words"] == ["Zeppelin"]


def test_get_notebook_denies_protected_then_allows_authenticated_clear(client):
    cli, token, path = client
    _seed(path)
    conn = _db(path)
    conn.execute(
        "UPDATE notebooks SET password_hash='hash', password_salt='salt', "
        "password_iterations=210000 WHERE id='nb-1'"
    )
    conn.commit()
    conn.close()

    response = _rpc(
        cli,
        token,
        "tools/call",
        {"name": "get_notebook", "arguments": {"notebook_id": "nb-1"}},
    )
    assert response.status_code == 200
    result = response.json()["result"]
    assert result["isError"] is True
    assert "password protected" in result["content"][0]["text"]
    assert "florist" not in result["content"][0]["text"]

    conn = _db(path)
    conn.execute(
        "UPDATE notebooks SET password_hash=NULL, password_salt=NULL, "
        "password_iterations=NULL, password_hash_prev='hash' WHERE id='nb-1'"
    )
    conn.commit()
    conn.close()
    payload = _call_tool(cli, token, "get_notebook", {"notebook_id": "nb-1"})
    assert "florist" in payload["text"]
    assert payload["handwriting_words"] == ["Zeppelin"]


def test_list_todos_default_hides_done(client):
    cli, token, path = client
    _seed(path)
    payload = _call_tool(cli, token, "list_todos", {})
    assert [t["id"] for t in payload["todos"]] == ["todo-1"]
    both = _call_tool(cli, token, "list_todos", {"include_done": True})
    assert {t["id"] for t in both["todos"]} == {"todo-1", "todo-done"}


# --- writes ---------------------------------------------------------------


def test_create_text_note_writes_row_and_change_log(client):
    cli, token, path = client
    payload = _call_tool(
        cli, token, "create_text_note", {"title": "From agent", "text": "Hello from MCP"}
    )
    note_id = payload["id"]
    conn = _db(path)
    row = conn.execute("SELECT * FROM dumps WHERE id = ?", (note_id,)).fetchone()
    assert row["mode"] == "text_note"
    assert row["transcript"] == "Hello from MCP"
    assert row["title"] == "From agent"
    change = conn.execute(
        "SELECT * FROM change_log WHERE entity_type = 'dump' AND entity_id = ?",
        (note_id,),
    ).fetchone()
    assert change["op"] == "upsert"
    assert change["device_id"] == "mcp"
    wire = json.loads(change["payload"])
    assert wire["transcript"] == "Hello from MCP"
    assert wire["mode"] == "text_note"
    conn.close()


def test_create_todo_writes_row_and_change_log(client):
    cli, token, path = client
    payload = _call_tool(
        cli, token, "create_todo", {"text": "Water plants", "due_date": "2026-10-05"}
    )
    todo_id = payload["id"]
    conn = _db(path)
    row = conn.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
    assert row["text"] == "Water plants"
    assert row["due_date"] == "2026-10-05"
    assert row["source"] == "manual"
    change = conn.execute(
        "SELECT * FROM change_log WHERE entity_type = 'todo' AND entity_id = ?",
        (todo_id,),
    ).fetchone()
    assert change["device_id"] == "mcp"
    wire = json.loads(change["payload"])
    assert wire["text"] == "Water plants"
    assert "google_task_id" not in wire  # Google bookkeeping stays server-only
    conn.close()


def test_create_todo_rejects_malformed_due_date(client):
    cli, token, _path = client
    response = _rpc(
        cli, token, "tools/call",
        {"name": "create_todo", "arguments": {"text": "x", "due_date": "next tuesday"}},
    )
    assert response.status_code == 200
    assert response.json()["result"]["isError"] is True

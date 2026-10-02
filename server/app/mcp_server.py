# SPDX-License-Identifier: AGPL-3.0-or-later
"""Remote MCP server: curated agent tools over the user's notes.

Mounted at /mcp on the main app (streamable HTTP, stateless, JSON
responses) per docs/design/2026-10-02-mcp-server.md. The tool surface is
hand-picked and calls the same helpers as the REST layer — it is NOT a
mirror of the REST API, so pairing/sync/setup internals never become
agent tools.

Auth: the MCP sub-app is plain ASGI (no FastAPI Depends), so the bearer
check lives in ``BearerAuthASGI`` — exactly ``require_auth``'s two
lookups (primary auth row, then unrevoked device tokens) against the
same SQLite file. A failed check answers 401 before the MCP transport
ever sees the request.

Lifecycle: ``build_mcp()`` returns a FRESH FastMCP per app because a
StreamableHTTPSessionManager can only ``run()`` once — a module-level
singleton would break the second TestClient lifespan in the suite.
"""

from __future__ import annotations

import contextlib
import json
import re
import sqlite3
import time
import uuid
from collections.abc import Iterator
from datetime import UTC, date, datetime
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from app.auth import hash_token
from app.config import get_settings
from app.db import _db_path, init_db
from app.services.speaker_names import render_speaker_names

MCP_DEVICE_ID = "mcp"


@contextlib.contextmanager
def _db() -> Iterator[sqlite3.Connection]:
    """Short-lived connection with the same pragmas as the REST dependency."""
    settings = get_settings()
    path = _db_path(settings.data_dir)
    if not path.exists():
        init_db(settings.data_dir)
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 30000")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _iso(ts: int | None) -> str | None:
    if not ts:
        return None
    # Notebook rows have historically carried milliseconds; normalize.
    if ts > 100_000_000_000:
        ts //= 1000
    return datetime.fromtimestamp(ts, tz=UTC).isoformat()


def _token_is_valid(db: sqlite3.Connection, token: str) -> bool:
    token_hash = hash_token(token)
    row = db.execute(
        "SELECT 1 FROM auth WHERE id = 1 AND token_hash = ?", (token_hash,)
    ).fetchone()
    if row is None:
        row = db.execute(
            "SELECT 1 FROM device_tokens WHERE token_hash = ? AND revoked_at IS NULL",
            (token_hash,),
        ).fetchone()
    return row is not None


class BearerAuthASGI:
    """ASGI wrapper enforcing the REST API's bearer scheme on the MCP mount."""

    def __init__(self, app: Any) -> None:
        self._app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return
        token = ""
        for key, value in scope.get("headers", []):
            if key == b"authorization":
                parts = value.decode("latin-1").split(" ", 1)
                if len(parts) == 2 and parts[0].lower() == "bearer":
                    token = parts[1].strip()
                break
        authorized = False
        if token:
            with _db() as conn:
                authorized = _token_is_valid(conn, token)
        if not authorized:
            body = json.dumps({"detail": "Invalid or missing bearer token"}).encode()
            await send(
                {
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"www-authenticate", b"Bearer"),
                        (b"content-length", str(len(body)).encode()),
                    ],
                }
            )
            await send({"type": "http.response.body", "body": body})
            return
        await self._app(scope, receive, send)


class MCPRouteMiddleware:
    """Dispatch /mcp (and any subpath) to the MCP app, bypassing the router.

    A plain ``app.mount("/mcp", ...)`` cannot serve the bare mount point:
    Starlette's Mount only matches ``/mcp/...`` and the router answers the
    exact path with a 307 to ``/mcp/`` — which curl and several MCP clients
    refuse to re-POST a body across. Owning the path prefix here means
    ``POST /mcp`` answers directly.
    """

    _PREFIX = "/mcp"

    def __init__(self, app: Any, mcp_app: Any) -> None:
        self._app = app
        self._mcp_app = mcp_app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] == "http":
            path = scope.get("path", "")
            if path == self._PREFIX or path.startswith(self._PREFIX + "/"):
                remainder = path[len(self._PREFIX):] or "/"
                child = {
                    **scope,
                    "path": remainder,
                    "root_path": scope.get("root_path", "") + self._PREFIX,
                }
                await self._mcp_app(child, receive, send)
                return
        await self._app(scope, receive, send)


def build_mcp() -> FastMCP:
    """Construct the Tangent MCP server with its curated tool surface."""
    mcp = FastMCP(
        "Tangent",
        instructions=(
            "Tools over the user's Tangent notes: voice recordings "
            "(transcripts + AI summaries), notebooks (typed text + "
            "handwriting), and to-dos. Use search_notes first for any "
            "content question; ids it returns feed the get_* tools."
        ),
        stateless_http=True,
        json_response=True,
        streamable_http_path="/",
        # The server deliberately listens on 0.0.0.0 so phones reach it over
        # LAN/Tailscale — Host-header pinning would reject every one of those
        # names. The gate is the bearer check in BearerAuthASGI, which runs
        # BEFORE the transport sees a request.
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=False
        ),
    )

    @mcp.tool()
    def search_notes(query: str, limit: int = 8) -> dict[str, Any]:
        """Full-text search across transcripts, summaries, notebooks (typed +
        handwriting) and to-dos. Returns ranked excerpts with entity ids."""
        from app.api.ask import retrieve

        bounded = max(1, min(int(limit), 25))
        with _db() as conn:
            chunks = retrieve(conn, query, bounded)
        return {
            "results": [
                {
                    "entity_type": c.entity_type,
                    "entity_id": c.entity_id,
                    "snippet": c.text[:280],
                    "created_at": _iso(c.created_at),
                    "seek_seconds": c.seek_seconds,
                }
                for c in chunks
            ]
        }

    @mcp.tool()
    def list_recordings(
        mode: str | None = None, limit: int = 20, offset: int = 0
    ) -> dict[str, Any]:
        """List recordings, newest first. mode filters to one of
        brain_dump / meeting / text_note."""
        if mode is not None and mode not in ("brain_dump", "meeting", "text_note"):
            raise ValueError("mode must be brain_dump, meeting, or text_note")
        bounded = max(1, min(int(limit), 200))
        where = "deleted_at IS NULL" + ("" if mode is None else " AND mode = ?")
        params: list[Any] = [] if mode is None else [mode]
        with _db() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) AS c FROM dumps WHERE {where}", params
            ).fetchone()["c"]
            rows = conn.execute(
                f"SELECT * FROM dumps WHERE {where} "
                "ORDER BY created_at DESC LIMIT ? OFFSET ?",
                [*params, bounded, max(0, int(offset))],
            ).fetchall()
        return {
            "total": total,
            "recordings": [
                {
                    "id": r["id"],
                    "title": r["title"],
                    "mode": r["mode"],
                    "created_at": _iso(r["created_at"]),
                    "duration_seconds": r["duration_seconds"],
                    "has_transcript": bool(r["transcript"] and r["transcript"].strip()),
                    "has_summary": bool(r["summary"] and r["summary"].strip()),
                    "folder_id": r["folder_id"],
                }
                for r in rows
            ],
        }

    @mcp.tool()
    def get_recording(recording_id: str) -> dict[str, Any]:
        """One recording: transcript (speaker names rendered), AI summary,
        meeting notes, and metadata."""
        with _db() as conn:
            row = conn.execute(
                "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL",
                (recording_id,),
            ).fetchone()
            if row is None:
                raise ValueError(f"Recording {recording_id!r} not found")
            transcript = row["transcript"]
            if transcript:
                transcript = render_speaker_names(transcript, row["speaker_names"])
        return {
            "id": row["id"],
            "title": row["title"],
            "mode": row["mode"],
            "created_at": _iso(row["created_at"]),
            "duration_seconds": row["duration_seconds"],
            "language": row["language"],
            "translated": bool(row["translated"]),
            "transcript": transcript,
            "summary": row["summary"],
            "meeting_notes": row["meeting_notes"],
            "folder_id": row["folder_id"],
        }

    @mcp.tool()
    def list_notebooks(limit: int = 50, offset: int = 0) -> dict[str, Any]:
        """List notebooks, most recently updated first."""
        bounded = max(1, min(int(limit), 200))
        with _db() as conn:
            total = conn.execute(
                "SELECT COUNT(*) AS c FROM notebooks WHERE deleted_at IS NULL"
            ).fetchone()["c"]
            rows = conn.execute(
                "SELECT id, title, created_at, updated_at, folder_id FROM notebooks "
                "WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT ? OFFSET ?",
                (bounded, max(0, int(offset))),
            ).fetchall()
        return {
            "total": total,
            "notebooks": [
                {
                    "id": r["id"],
                    "title": r["title"],
                    "created_at": _iso(r["created_at"]),
                    "updated_at": _iso(r["updated_at"]),
                    "folder_id": r["folder_id"],
                }
                for r in rows
            ],
        }

    @mcp.tool()
    def get_notebook(notebook_id: str) -> dict[str, Any]:
        """One notebook: typed text extracted from the document plus the
        recognized handwriting words, in written order."""
        from app.api.ask import _json as parse_json
        from app.api.ask import _strings

        with _db() as conn:
            row = conn.execute(
                "SELECT * FROM notebooks WHERE id = ? AND deleted_at IS NULL",
                (notebook_id,),
            ).fetchone()
            if row is None:
                raise ValueError(f"Notebook {notebook_id!r} not found")
            words = [
                r["word_text"]
                for r in conn.execute(
                    "SELECT word_text FROM ink_index WHERE notebook_id = ? "
                    "ORDER BY line_id, id",
                    (notebook_id,),
                )
            ]
        typed = " ".join(_strings(parse_json(row["doc"], row["doc"])))
        return {
            "id": row["id"],
            "title": row["title"],
            "created_at": _iso(row["created_at"]),
            "updated_at": _iso(row["updated_at"]),
            "folder_id": row["folder_id"],
            "text": typed,
            "handwriting_words": words,
        }

    @mcp.tool()
    def list_todos(include_done: bool = False, limit: int = 100) -> dict[str, Any]:
        """List to-dos, newest first. Done items are hidden unless asked for."""
        bounded = max(1, min(int(limit), 500))
        where = "deleted_at IS NULL" + ("" if include_done else " AND done_at IS NULL")
        with _db() as conn:
            rows = conn.execute(
                f"SELECT * FROM todos WHERE {where} "
                "ORDER BY created_at DESC LIMIT ?",
                (bounded,),
            ).fetchall()
        return {
            "todos": [
                {
                    "id": r["id"],
                    "text": r["text"],
                    "due_date": r["due_date"],
                    "done": r["done_at"] is not None,
                    "done_at": r["done_at"],
                    "folder_id": r["folder_id"],
                    "created_at": r["created_at"],
                }
                for r in rows
            ]
        }

    @mcp.tool()
    def create_text_note(title: str, text: str) -> dict[str, Any]:
        """Create a text note. It syncs to every paired device."""
        from app.api.dumps import _publish_dump_change

        title = title.strip()
        text = text.strip()
        if not title or not text:
            raise ValueError("title and text must both be non-empty")
        note_id = str(uuid.uuid4())
        now = int(time.time())
        with _db() as conn:
            conn.execute(
                "INSERT INTO dumps (id, client_id, mode, duration_seconds, title, "
                "created_at, updated_at, transcript, audio_kept) "
                "VALUES (?, ?, 'text_note', 0, ?, ?, ?, ?, 0)",
                (note_id, MCP_DEVICE_ID, title, now, now, text),
            )
            _publish_dump_change(conn, note_id, MCP_DEVICE_ID)
        return {"id": note_id, "title": title, "created_at": _iso(now)}

    @mcp.tool()
    def create_todo(text: str, due_date: str | None = None) -> dict[str, Any]:
        """Create a to-do. due_date is an optional YYYY-MM-DD string.
        It syncs to every paired device (and onward to Google Tasks when
        that integration is connected)."""
        from app.services.change_log import record_change
        from app.services.google_tasks_worker import _todo_payload

        text = text.strip()
        if not text:
            raise ValueError("text must be non-empty")
        if due_date is not None:
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", due_date) is None:
                raise ValueError("due_date must be YYYY-MM-DD")
            try:
                date.fromisoformat(due_date)
            except ValueError as exc:
                raise ValueError(f"due_date is not a real date: {due_date}") from exc
        todo_id = str(uuid.uuid4())
        now_iso = datetime.now(tz=UTC).isoformat()
        with _db() as conn:
            conn.execute(
                "INSERT INTO todos (id, text, done_at, due_date, source, source_ref, "
                "folder_id, created_at, updated_at) "
                "VALUES (?, ?, NULL, ?, 'manual', NULL, NULL, ?, ?)",
                (todo_id, text, due_date, now_iso, now_iso),
            )
            row = conn.execute(
                "SELECT * FROM todos WHERE id = ?", (todo_id,)
            ).fetchone()
            record_change(
                conn,
                entity_type="todo",
                entity_id=todo_id,
                op="upsert",
                device_id=MCP_DEVICE_ID,
                payload=_todo_payload(row),
            )
        return {"id": todo_id, "text": text, "due_date": due_date}

    return mcp

# Remote MCP server (v1.46.0)

**Status:** approved (Jeff, 2026-10-02 chat) — "Go ahead with B."

## What

A Model Context Protocol endpoint built into the existing Tangent server
container, so AI agents (Hermes, Claude Code, anything MCP-capable) can
search and read the user's notes — and add to them — over the same port
and the same bearer tokens as the REST API. No new service, no compose
change.

Option B from the evaluation: the official `mcp` Python SDK (FastMCP),
**curated tools calling the service layer directly** — NOT an
auto-generated mirror of the REST surface (option A, `fastapi-mcp`,
rejected: it exposes pairing/sync internals as agent tools and makes a
noisy, dangerous palette).

## Transport & mounting

- Streamable HTTP, **stateless**, JSON responses
  (`FastMCP(stateless_http=True, json_response=True,
  streamable_http_path="/")`), mounted at **`/mcp`** on the main FastAPI
  app. Endpoint: `http://<host>:8765/mcp` (host port per compose).
- The MCP session manager's lifespan runs inside the existing app
  lifespan (`async with mcp.session_manager.run(): yield`).
- Stateless by design: every POST is independent, no session affinity,
  so container restarts and multiple agents Just Work.

## Auth

Same credentials as the REST API: the primary setup token or any live
(unrevoked) device token minted by pairing. The MCP sub-app is not a
FastAPI router, so auth is an ASGI wrapper (`BearerAuthASGI`) around the
mounted app performing exactly the `require_auth` checks (same two
queries, same `hash_token`). Missing/bad token → 401 JSON with
`WWW-Authenticate: Bearer`, request never reaches the MCP transport.

## Tools (v1 surface)

Read (names use the user-facing word "recording"; ids are dump ids):

| tool | args | returns |
|---|---|---|
| `search_notes` | `query`, `limit=8` | ranked excerpts over transcripts, summaries, notebooks (typed + ink index) and todos — reuses `app.api.ask.retrieve` (FTS5/BM25 + recency boost) |
| `list_recordings` | `mode=None`, `limit=20`, `offset=0` | id, title, mode, created_at (ISO), duration_seconds, has_transcript, has_summary, folder_id |
| `get_recording` | `recording_id` | full transcript with speaker names rendered (`render_speaker_names`), summary, meeting_notes, language, metadata |
| `list_notebooks` | `limit=50`, `offset=0` | id, title, created/updated (ISO), folder_id |
| `get_notebook` | `notebook_id` | title, typed text (extracted from the opaque doc), handwriting words from `ink_index` |
| `list_todos` | `include_done=False`, `limit=100` | id, text, due_date, done, folder_id |

Write (both publish to `change_log` so every paired device pulls them):

| tool | args | effect |
|---|---|---|
| `create_text_note` | `title`, `text` | new dump, `mode='text_note'`, transcript = text, published via `_publish_dump_change` with device id `mcp` |
| `create_todo` | `text`, `due_date=None` (YYYY-MM-DD) | new todo, `source='manual'`, published with the exact `_todo_payload` projection (Google bookkeeping never exposed) |

Deliberately absent in v1: deletes, edits, transcription control,
pairing, settings. Additive later if wanted.

## Non-goals / constraints

- No OAuth flow — bearer only, matching the app's single-user model.
- Deleted entities (`deleted_at`) are invisible to every tool.
- Server-only columns (Google ids, embeddings) never appear in results.
- Offline-first unaffected: MCP is an additional reader/writer on the
  same local SQLite, nothing moves to a cloud.

## Testing

`tests/test_mcp.py`, plain JSON-RPC POSTs against the mounted endpoint
through `TestClient` (stateless mode means no handshake needed):
401 without/with-bad token; `tools/list` names; `search_notes` finds a
seeded transcript; `get_recording` renders speaker names; `create_text_note`
and `create_todo` write rows AND change_log entries with correct payloads;
deleted rows excluded.

# Google Tasks sync — design (2026-09-27)

Jeff: "how can we connect this to google services? Is it free?" → "go ahead
and spec that once the folder lands" → "lets go ahead and start the google
task".

Ships as **v1.25.0**. Server-heavy; the client half is one Settings section.

## Jeff's picks (recorded)

- **G1 Two-way, last-write-wins.** Edit / check / uncheck / delete on either
  side; the newer change wins. Same rule as Tangent's own device sync.
- **G2 Every to-do → one Google list named "Tangent".** Folders do NOT map
  (Google has flat lists, no folders); `folder_id` stays Tangent-only and is
  never touched by a Google-side change.
- **G3 Server-side on `tangent-server`.** One Google sign-in for the
  household; tokens live in the server DB, never on a device; syncs while
  the phones sleep. Off by default behind a Settings section, same as
  handwriting search and AI summaries.

## Is it free — answer on record

Yes. Google Tasks API: $0, courtesy quota 50,000 queries/day (we will use
< 300/day at a 5-minute poll). The cost is OAuth ceremony:

- Jeff creates a Google Cloud project (free), enables *Tasks API*, creates an
  **OAuth client of type "Desktop app"** (works for the device/loopback
  flow), and configures the consent screen with himself as a test user.
- In **Testing** publishing status, refresh tokens **expire after 7 days**
  (Google policy, external user type). The server must surface this as a
  "Reconnect Google" state, not a silent stall. Moving the consent screen to
  **In production** removes the 7-day cap; for `auth/tasks` (a sensitive
  scope) Google asks for verification only if the app is made public — a
  single-user app can be marked In production *unverified*; users then see
  an "unverified app" interstitial once, which Jeff can click through. That
  is the intended end state; `[default]` ship in Testing, document the
  upgrade step in the Settings help text.
- Nothing is uploaded except task title / due date / done / deleted. No
  transcripts, no recordings, no notebooks.

## Server

### Auth (Ted)

- `pip` dep: `google-auth` + `google-auth-oauthlib` (+ `requests`). No
  `google-api-python-client` — call the four REST endpoints with `requests`;
  the discovery client is heavy and version-churny.
- Table `google_tasks_link` (single row): `client_id`, `client_secret`
  (Jeff pastes both once; stored server-side only), `refresh_token`,
  `access_token`, `access_expires_at`, `google_email`, `tasklist_id`,
  `last_pull_updated_min` (RFC 3339), `status` in
  (`disconnected`, `pending`, `connected`, `reauth_required`, `error`),
  `last_error`, `last_sync_at`.
- Endpoints (bearer-auth like everything else):
  - `GET /v1/google-tasks/status` → status + email + last_sync_at +
    last_error + counts (`pushed`, `pulled` last cycle).
  - `POST /v1/google-tasks/credentials` `{client_id, client_secret}` →
    stores, status `disconnected`.
  - `POST /v1/google-tasks/connect` → starts the **OAuth device-style
    loopback flow on the server**: returns `{auth_url}`; the client opens it
    in the phone browser; Google redirects to `http://<server>:8765/v1/
    google-tasks/callback?code=…&state=…` (the server is on the LAN /
    Tailscale, the phone browser can reach it — the same address the app
    already talks to). Callback exchanges the code, stores tokens, finds or
    creates the "Tangent" tasklist, sets status `connected`, returns a
    plain "Connected — you can close this tab" page.
  - `POST /v1/google-tasks/disconnect` → revokes the token at Google, clears
    tokens (keeps client id/secret), status `disconnected`. Local to-dos
    untouched; Google list untouched.
  - `POST /v1/google-tasks/sync-now` → runs one cycle inline, returns the
    status payload.
- `state` is a random nonce stored with a 10-minute expiry; the callback
  rejects a mismatch.

### Mapping

`todos` gains `google_task_id TEXT NULL` + `google_updated TEXT NULL`
(server-only columns, NOT in the sync payload — devices never see them;
`_apply_todo` must not clear them on upsert, so they live outside the
`INSERT … ON CONFLICT DO UPDATE` column list).

| Tangent | Google Task |
|---|---|
| `text` | `title` (≤1024; truncate with `…`) |
| `due_date` (YYYY-MM-DD) | `due` (`YYYY-MM-DDT00:00:00.000Z`; Google keeps date only) |
| `done_at != null` | `status: completed`, `completed: <done_at>` |
| `done_at == null` | `status: needsAction` (and `completed` omitted) |
| `deleted_at != null` | `tasks.delete` (hard delete at Google; Google's own `deleted: true` tombstone maps back to a Tangent soft delete) |
| `updated_at` | `updated` (read-only at Google; used for LWW only) |
| `folder_id`, `source`, `source_ref` | not sent |

### The cycle (`services/google_tasks_worker.py`)

Runs every **5 minutes** `[default]` when status is `connected`, and on
`sync-now`. One cycle:

1. **Refresh access token** if within 60 s of expiry. A refresh failure with
   `invalid_grant` → status `reauth_required`, stop; anything else → `error`
   with the message, retry next cycle.
2. **Push:** every non-deleted todo whose `updated_at > google_updated` (or
   `google_task_id IS NULL`) → `insert` or `patch`; store the returned `id`
   and `updated` as `google_task_id` / `google_updated`. Every todo with
   `deleted_at` set and a `google_task_id` → `delete`, then clear
   `google_task_id` (idempotent: a 404 counts as done).
3. **Pull:** `tasks.list(tasklist, updatedMin=last_pull_updated_min,
   showCompleted=true, showHidden=true, showDeleted=true)`, paginate. For
   each task:
   - `deleted: true` → if a todo has that `google_task_id` and is not
     already soft-deleted, soft-delete it (server-authored change, recorded
     in `change_log` so devices pull it).
   - Known `google_task_id` → **LWW:** apply only if Google's `updated` >
     the todo's `updated_at`; write `text`/`due_date`/`done_at`, bump
     `updated_at` to Google's `updated`, `google_updated` likewise, record
     the change.
   - Unknown id, not deleted → create a todo (`source='google'`,
     `source_ref=<task id>`, `folder_id` null, `google_task_id` set), record
     the change.
   - `last_pull_updated_min` = max `updated` seen (minus 1 s for clock skew).
4. **Echo guard:** a push updates `google_updated` to Google's new
   `updated`; the next pull sees `updated == google_updated` and skips it, so
   our own writes never bounce back as edits.

Server-authored writes go through the same helper the summarizer worker
uses to record `change_log` entries (they bypass the device newer-wins gate
exactly like `transcript_timings` does — see AGENTS.md v1.12.0 note).

### Server tests (`tests/test_google_tasks.py`), all against a fake Google
(`responses`/`httpx` mock — no network):

- status transitions: disconnected → connect → connected; `invalid_grant`
  → reauth_required; disconnect clears tokens and keeps credentials.
- mapping both directions (due date → midnight Z and back; done ↔ status).
- push creates then patches (second cycle sends `patch`, not `insert`).
- pull LWW: Google newer wins, Tangent newer is kept, equal is skipped.
- echo guard: a push is not re-applied by the following pull.
- Google `deleted: true` → soft delete + change_log entry.
- Tangent soft delete → `tasks.delete`; 404 tolerated; id cleared.
- unknown Google task → new todo with `source='google'`.
- `_apply_todo` upsert from a device does NOT clear `google_task_id`.
- worker skips the cycle entirely when status ≠ connected.
- Sabotages: (S1) drop the `updated >` comparison → LWW test fails; (S2)
  include `google_task_id` in the ON CONFLICT column list → the
  device-upsert-preserves test fails; (S3) skip `showDeleted` → the
  Google-delete test fails.

## Client (one Settings section, `google_tasks_section.dart`)

Modelled on `ai_summaries_section.dart`: polls `/v1/google-tasks/status`.

- **Disconnected, no credentials:** two text fields *Client ID* / *Client
  secret* + *Save*, with a 4-line help text: "Free. Create a Google Cloud
  project, enable the Tasks API, add an OAuth client (Desktop app), paste
  both here." and a link to the doc page.
- **Disconnected, credentials saved:** *Connect Google* → opens `auth_url`
  in the system browser (`url_launcher`, already a dep). Status flips to
  connected on the next poll.
- **Connected:** "Connected as jeff@…", *Last sync 2 min ago · 3 pushed ·
  1 pulled*, *Sync now*, *Disconnect*.
- **Reauth required:** amber banner "Google needs you to sign in again
  (test-mode tokens expire weekly)" + *Reconnect*.
- **Error:** red line with `last_error` + *Retry*.
- Keys: `google-tasks-client-id`, `google-tasks-client-secret`,
  `google-tasks-save`, `google-tasks-connect`, `google-tasks-sync-now`,
  `google-tasks-disconnect`, `google-tasks-reconnect`, `google-tasks-status`.
- To Do list: a to-do with `source='google'` shows a tiny "G" chip
  (`todo-google-chip-<id>`) so you know where it came from. Nothing else
  on the client changes — Google-side edits arrive through the existing
  sync pull like any other device's edits.
- Client tests: section renders each of the five states from a fake status
  payload; Connect launches the URL; the "G" chip appears only for
  `source == 'google'`. Sabotage: chip shown for every source → test fails.

## Not in this arc

- Folders ↔ lists (G2). Notes field. Subtasks. Google Calendar. Assigned
  tasks from Docs/Chat (`showAssigned` stays false).
- Verification submission to Google — Jeff's call after it has run a week.

## Gates

Server: pytest must not regress (559 passed, 3 skipped) + the new file.
Client: analyze zero issues, full suite green (baseline +2321 ~2).
Device proof before tagging: Jeff pastes real credentials on the S11 Ultra
→ Connect → Google's consent page → "Connected" → within 5 minutes the
"Tangent" list exists in the Google Tasks app with today's to-dos; tick one
off in Google → it shows Done on the Fold; add one on the Fold → it appears
in Google. Credentials/tokens are never quoted in chat or logs.

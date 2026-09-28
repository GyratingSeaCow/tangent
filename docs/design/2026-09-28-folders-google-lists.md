# Folders ↔ Google lists + immediate Google push (2026-09-28)

Ships as **v1.30.0**. Server half (Ted): folder↔list mapping. Client half
(small): the To Do sync button also runs one Google cycle.

Supersedes G2 of `2026-09-27-google-tasks-sync.md` ("every to-do → one
list 'Tangent'; folders don't map").

## Jeff's picks (recorded)

- **L1 Google → Tangent follows moves.** Dragging a task to another
  Tangent-managed list in Google moves it to that folder; moving it to a
  list Tangent does not manage (or one whose folder was deleted) unfiles
  it (`folder_id = NULL`, and the task is moved back to the "Tangent"
  list on the next push so the two sides agree).
- **L2 "Tangent" stays the list for unfiled to-dos.** Each folder gets a
  Google list named exactly like the folder (no prefix).
- **L3 Deleting a folder in Tangent deletes its (now empty) Google list**
  after its tasks have been moved to "Tangent".
- **L4 To Do's ↻ also runs one Google cycle** right after the device push;
  snackbar `Synced · Google updated` (or `Synced · Google: <error>` /
  plain `Synced…` when Google is not connected).

## Data model (server, `db.py`, guarded ALTERs like v1.25.0)

- `folders.google_tasklist_id TEXT NULL` — server-only, projected OUT of
  the sync feed exactly like `todos.google_task_id` (never in the pull
  payload; preserved across device upserts of the folder row — extend the
  v1.25 "device upsert preserves mapping" rule and its test to folders).
- `google_tasks_link.tasklist_id` keeps meaning "the unfiled list".
- `todos.google_tasklist_id TEXT NULL` — the list the task currently
  lives in ON GOOGLE (server-only, same projection rule). Needed because
  a move must name the SOURCE list (`POST /lists/{src}/tasks/{id}/move?
  destinationTasklist={dst}`), and a task's folder can change on either
  side between cycles.

## Worker rules (`google_tasks_worker.py`)

### Lists
1. `ensure_lists(db, token)` each cycle: for every live folder without a
   `google_tasklist_id`, find a list with that exact title (re-adopt on
   reconnect) or create it; store the id. Two folders with the same name:
   the older `created_at` owns the list, the newer gets `"<name> (2)"`.
2. Folder renamed in Tangent → `PATCH lists/{id}` title. Folder soft-
   deleted in Tangent (L3) → move each task still in that list to the
   unfiled list, then `DELETE lists/{id}`, clear the mapping. A 404 on any
   of these is treated as already-done.
3. Lists the user creates in Google that match no folder are NOT imported
   as folders (one-way for lists; tasks in them are "unmanaged").

### Push (Tangent → Google)
4. Target list for a todo = folder's `google_tasklist_id` if the folder is
   live and mapped, else the unfiled list. If the todo already has a
   `google_task_id` and `google_tasklist_id != target` → `tasks.move`
   with `destinationTasklist` (keeps the id), then patch as today. New
   tasks are inserted directly into the target. Record
   `google_tasklist_id` after every insert/move.

### Pull (Google → Tangent, L1)
5. Pull iterates **every managed list** (unfiled + each folder's) with the
   per-list `updatedMin` stored in a new table
   `google_list_cursor(tasklist_id PRIMARY KEY, updated_min TEXT)`;
   the old single `last_pull_updated_min` on the link row migrates in as
   the unfiled list's cursor.
6. A task seen in list L whose local `google_tasklist_id != L` was moved in
   Google: set `folder_id` to L's folder (or NULL when L is the unfiled
   list), set `google_tasklist_id = L`, write a server-authored change_log
   entry (devices pull it like any edit; `folder_id` is a synced field).
   Only if the task's `updated` is newer than the local `updated_at` — the
   existing LWW gate — so a same-second Tangent move is not undone.
7. A task that vanishes from every managed list without `deleted: true`
   (moved to an unmanaged list): treat as **unfiled** (L1 second clause):
   `folder_id = NULL`, and the next push moves it back to the unfiled list.
   Detection: the task's id is absent from the full listing of its
   recorded list AND `tasks.get` on that list 404s. Do this check only for
   tasks whose recorded list returned a delta (cheap), never a full scan.

### Echo guard
8. Everything the worker writes to Google records `google_updated` as
   today, so its own moves are not re-applied on the next pull.

## Endpoint change
- `POST /v1/google-tasks/sync-now` unchanged in shape; `GoogleTasksStatus`
  gains `lists: [{"name": ..., "tasklist_id": ..., "folder_id": ...}]`
  (the unfiled list has `folder_id: null`) so Settings can show the
  mapping, and `last_cycle: {"pushed": n, "pulled": n, "moved": n}`.

## Client half (L4)
- `SyncButton` gains an optional `afterSync: Future<String?> Function()?`
  hook; the To Do screen passes one that calls
  `SummariesClient.googleTasksSyncNow()` when the status is `connected`
  and returns ` · Google updated` / ` · Google: <last_error>`; other
  screens pass nothing (their snackbar is unchanged). The hook runs AFTER
  the device sync so the just-pushed change is what Google receives.
- Settings → Google Tasks connected state lists the mapped lists.

## Migration of the live data
On first cycle after deploy: 4 folders (Personal, Work, Bugs, Shop) →
4 new lists; the 2 filed todos move out of "Tangent" into Personal / Shop;
the 13 unfiled stay. Nothing is deleted on Google.

## Tests (server `test_google_tasks.py`, mocked `requests` as before)
- ensure_lists: creates / re-adopts by title / dedupes names / renames /
  deletes-after-move on folder delete / 404 = done.
- push: new task lands in the folder's list; folder change → `move` call
  with `destinationTasklist` and the SAME task id, then patch; unfiled →
  unfiled list; folder deleted → task moved to unfiled.
- pull: task in a different list than recorded → folder_id follows +
  change_log row; LWW gate blocks an older Google move; task gone from all
  managed lists → unfiled; per-list cursors advance independently; the old
  link cursor migrates.
- projection: `google_tasklist_id` (todos and folders) never in the pull
  feed; device upsert of a folder preserves its mapping.
- status: `lists` and `last_cycle` present.

Sabotages (quote real output): (S1) push ignores folder → "new task lands
in the folder's list" fails; (S2) move implemented as delete+insert → the
"SAME task id" assertion fails; (S3) pull applies a Google move that is
OLDER than the local edit → LWW test fails; (S4) folder delete skips the
move-out → the "tasks survive folder deletion" test fails; (S5) leak
`google_tasklist_id` into the feed → projection test fails.

Client: widget test that To Do's ↻ calls the hook after the sync and the
snackbar reads `Synced: sent 1 · Google updated`; Recordings' button does
not call it. Sabotage (C1): hook before sync → ordering test fails.

## Gates
Server: pytest must not regress (baseline 586 passed, 3 skipped). Client:
analyze clean, full suite green (baseline +2517 ~2). Proof: after deploy,
Jeff sees lists Personal / Work / Bugs / Shop / Tangent in Google with the
right tasks; drags one task from Tangent to Shop in Google → within 5 min
it shows in Shop in Tangent; ↻ on To Do says `Synced · Google updated`.

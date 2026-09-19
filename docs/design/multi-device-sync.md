# Multi-device sync — design

Status: proposed. Nothing here is implemented yet.

Tangent today syncs one way: `SyncEngine` uploads dumps to the owner's server
as opt-in backup. There is no pull, no device identity, and no conflict
handling. This document designs the two-way case for **every** self-hosted
user, not one person's hardware.

---

## 1. Scope

**Syncs:** notebooks (ink + typed blocks + card references), text notes, dump
metadata, transcripts.

**Does not sync:** audio files. Audio stays on the device that recorded it and
transfers only when the user explicitly asks. Audio is large and private, and
a local-first recorder should not silently copy every recording to every
device. A dump that exists on device B without its audio is a first-class
state, not an error.

**Hub:** the user's own server. No third-party cloud, ever.

**Offline-first:** every device stays fully usable with no server reachable and
reconciles later. Sync is never on the critical path of capturing a thought.

---

## 2. The model: server-assigned change sequence, per-entity merge

The server owns a single monotonically increasing `change_seq`. Every mutation
it accepts is stamped with the next value. A client remembers the highest
`change_seq` it has seen and asks "what changed after N?".

This is a **checkpoint**, not a clock. It is assigned by one authority, so it
does not care whether a tablet's clock is ten minutes fast.

### Rejected alternatives

**Last-write-wins on `updatedAt`.** Simplest, and wrong here. It makes
correctness depend on device wall-clocks, which are routinely skewed and
occasionally reset by the user. Worse, at whole-notebook granularity it means
the loser's handwriting silently vanishes — a page of ink destroyed because
another device saved a title edit a second later. Rejected on data loss.

**Vector clocks.** Correct and genuinely captures causality, but every device
must carry a vector of every other device it has ever seen, entries must be
pruned when devices die, and debugging a stuck merge means reading a matrix.
This is maintained by one developer. Rejected on operational cost, not
correctness.

**Full CRDT (e.g. Automerge/Yjs).** The right answer for concurrent rich-text
editing. Tangent's notebooks are not concurrently edited documents — one
person moves between their own devices, usually minutes or hours apart. A CRDT
would add a large dependency and a rewrite of the notebook model to solve
contention that mostly does not happen. Rejected as disproportionate, with one
borrowed idea: ink is treated as a grow-only set, below.

**Operation log / event sourcing.** Attractive and exact, but it makes every
notebook an unbounded log that must be compacted, and the client must replay
history to render a page. Rejected on storage growth for an app whose users
self-host on modest hardware.

### The borrowed idea: ink is a grow-only set

`InkStroke` has a stable `id` and is immutable once drawn — the code never
edits a stroke's points; erasing removes whole strokes (`notebook_ink_canvas.dart`
erases by stroke, not by pixel). That makes ink a set of opaque items, and sets
merge without conflict: union the strokes, then subtract the tombstoned ones.

So two devices writing on the same page while both offline produce **both**
sets of handwriting, not one surviving version. That is the single most
important property in this document, and it is only available because strokes
are already immutable and identified.

---

## 3. Entities and their merge rules

| Entity | Granularity | Rule |
|---|---|---|
| Ink strokes | per stroke | Union by stroke id. Erase = tombstone. Never overwritten. |
| Typed text block | per block | Field-level. Concurrent edits to the *same* block keep both as sibling blocks (see below) rather than discarding one. |
| Block position (x/y) | per block | Higher `change_seq` wins. A lost drag is a trivial loss; the user drags again. |
| Checkbox state | per block | Higher `change_seq` wins. |
| Block added / deleted | per block | Add wins over concurrent delete (resurrect-on-edit is less bad than silent loss). |
| Notebook title | per notebook | Higher `change_seq` wins. |
| Card reference | per card | Union; delete tombstones. |
| Dump metadata (title) | per dump | Higher `change_seq` wins. |
| Transcript | per dump | Existing `revision` uuid already guards this; keep it. A newer revision wins; equal revisions are identical by construction. |
| Dump / notebook delete | per entity | Tombstone, see §6. |

### Concurrent edits to one text block

If device A and device B both edit block `X` while offline, the merge keeps the
higher-`change_seq` text in block `X` and inserts the loser immediately below
as a new block, prefixed `⑂ `. Nothing is destroyed, the user sees both, and
deleting the duplicate is one gesture.

This is deliberately dumber than a text CRDT. For an app where the same person
edits their own note from two devices hours apart, an occasional visible
duplicate is a better failure than an invisible deletion.

---

## 4. Device identity

A device generates a UUIDv4 `device_id` on first run and stores it in the local
DB (not in shared preferences — it must survive with the data it describes, and
die with it on uninstall).

`POST /v1/devices` registers `{device_id, display_name, platform}`. Re-running
it is idempotent. A reinstall yields a new id and simply syncs everything from
`change_seq = 0`; the stale device row is harmless and can be deleted from the
server UI later.

**Auth is unchanged.** The existing single shared bearer token still identifies
the *user*; `device_id` identifies the *replica*. Multi-device does not require
multi-user auth, and adding accounts now would be scope creep. Devices are
listed on the server so a user can see what is syncing.

---

## 5. Schema changes

### Server (SQLAlchemy)

```
change_log
  seq          INTEGER PRIMARY KEY AUTOINCREMENT   -- the global sequence
  entity_type  TEXT NOT NULL        -- 'dump' | 'notebook' | 'note'
  entity_id    TEXT NOT NULL
  op           TEXT NOT NULL        -- 'upsert' | 'delete'
  device_id    TEXT NOT NULL        -- who authored it (echo suppression)
  payload      JSON                 -- full entity for upsert, null for delete
  created_at   DATETIME NOT NULL

devices
  device_id    TEXT PRIMARY KEY
  display_name TEXT NOT NULL
  platform     TEXT NOT NULL
  last_seen_seq INTEGER NOT NULL DEFAULT 0
  last_seen_at DATETIME
```

Existing `dumps` gains `deleted_at DATETIME NULL` (tombstone) and
`origin_device_id TEXT NULL` (which device holds the audio).

### Client (Drift)

`dumps` gains:
- `serverSeq INTEGER NULL` — the `change_seq` this row was last confirmed at
- `dirty BOOLEAN NOT NULL DEFAULT FALSE` — local edits awaiting push
- `deletedAt DATETIME NULL`
- `audioLocation TEXT NOT NULL DEFAULT 'local'` — `local` | `remote` | `fetching` | `unavailable`
- `originDeviceId TEXT NULL`

New tables:
- `sync_state(key TEXT PRIMARY KEY, value TEXT)` — holds `device_id` and `last_seq`
- `ink_tombstones(strokeId TEXT PRIMARY KEY, notebookId TEXT, deletedAt DATETIME)`

Ink tombstones are required: without them, a stroke erased on A reappears from
B's copy on the next union. Retention is covered in §6.

---

## 6. Deletes and tombstones

Deletes are tombstones, never row removal, or a delete on A is undone by B's
next push.

- Entity deletes live in `change_log` with `op='delete'` and are retained for
  **180 days**, then hard-deleted along with the entity.
- Ink tombstones travel inside the notebook payload as a `deletedStrokeIds`
  array, retained for the same 180 days.
- A device offline longer than the retention window cannot be safely merged —
  it may resurrect deleted content. On reconnect, if `last_seq` is older than
  the oldest retained `change_log` row, the client discards its checkpoint and
  performs a **full resync** (§7.3), which is correct if slower.

180 days is a deliberate trade: long enough that a tablet in a drawer over a
summer still merges, short enough that the log does not grow without bound.

---

## 7. The algorithm

### 7.1 Normal sync

1. `POST /v1/sync/pull {device_id, since_seq}` → `{changes: [...], head_seq}`.
2. Apply each change locally, skipping any whose `device_id` is mine (echo).
   Merge per §3. Record `serverSeq`.
3. Collect local rows where `dirty = true`.
4. `POST /v1/sync/push {device_id, changes: [...]}` → per-entity
   `{entity_id, seq, status}`.
5. On `status='applied'`, clear `dirty` and store the new `serverSeq`.
6. Store `head_seq` as `last_seq`.

Pull-then-push, so a client merges the server's view before adding to it, and
the push carries an already-merged entity.

### 7.2 First sync on a new device

`since_seq = 0` pulls everything. Every dump arrives with
`audioLocation='remote'`. Notebooks and transcripts are immediately usable;
tapping a recording offers to fetch its audio.

### 7.3 Full resync (checkpoint too old, or corruption)

Pull with `since_seq=0`, merge into the existing local store rather than
replacing it (local-only rows survive), then push everything still `dirty`.
Idempotent by entity id.

### 7.4 Audio on demand

`audioLocation` state machine:

```
local ────────────────────────────── recorded here; the file is present
remote ──(user taps Fetch)──> fetching ──(200)──> local
                                  └────(404/offline)──> unavailable
unavailable ──(origin device syncs)──> remote
```

`GET /v1/dumps/{id}/audio` already exists. If the origin device never uploaded
the audio, the server answers 404 and the UI says *"Audio is on <device name>.
Open Tangent there while online to make it available."* — which names the
actual next action instead of showing a dead play button.

---

## 8. Failure modes

| Failure | Behaviour | User sees |
|---|---|---|
| Server unreachable | Queue locally, retry with backoff | "Last synced 2h ago", no error spam |
| Auth token wrong | Stop; do not retry-loop | "Reconnect to your server" |
| Push conflict (entity changed since pull) | Re-pull that entity, re-merge, push again (max 3), then mark for manual review | Nothing, unless it exhausts retries |
| Checkpoint older than retention | Full resync | "Catching up…" progress |
| Partial push failure | Per-entity status; successes stay applied | Silent, retried |
| Audio missing at origin | Tombstone-free `unavailable` | "Audio is on <device>" |
| Clock skew | Irrelevant by design | — |

---

## 9. Phased plan

Each phase ships independently and leaves the app working.

1. **Device identity.** `device_id`, `sync_state` table, `POST /v1/devices`, device list on the server. *Accepts:* id is stable across restarts, unique per install.
2. **Change log, server side.** `change_log` table, stamping on existing writes, `GET /v1/sync/pull`. *Accepts:* a mutation appends exactly one row; pull returns changes after N in order.
3. **Pull-only client.** Apply remote changes; no push yet. *Accepts:* a dump created on the server appears locally; echoes are suppressed.
4. **Push.** Dirty tracking, `POST /v1/sync/push`, retry. *Accepts:* offline edit reaches the server on reconnect.
5. **Notebook merge.** Stroke union, ink tombstones, block rules from §3. *Accepts:* two offline devices both keep their handwriting; erasing on one does not resurrect from the other.
6. **Deletes.** Tombstones, retention, full-resync fallback. *Accepts:* delete on A stays deleted on B; a stale device triggers full resync.
7. **Audio on demand.** `audioLocation` machine, fetch UI, the "on device X" state. *Accepts:* dump plays on B after explicit fetch; graceful 404.
8. **Migration.** Existing rows get `serverSeq=null, dirty=true`; first sync reconciles by id. *Accepts:* an upgrade with existing dumps neither duplicates nor loses any.

### Existing tests this touches

- `client/test/**/sync_*`, and anything constructing `DumpRow` (new non-null columns with defaults).
- `server/tests/test_dumps.py` — writes now also append a `change_log` row.
- Notebook model tests — `deletedStrokeIds` in the JSON payload; `tryFromJson` must stay tolerant of its absence so old files still load.
- The 1013 Flutter / 125 server tests are green today and must stay green per phase.

---

## 10. Open questions

1. **Sync trigger.** On app resume, on a timer, on every local edit, or manual only? Given "no idle work" as a standing preference, resume + manual is the likely answer, but it is the user's call.
2. **Wi-Fi gate.** `wifiOnlySync` currently gates upload. Metadata sync is tiny (kilobytes) and arguably should ignore it, while audio fetch clearly should respect it. Proposal: metadata always, audio Wi-Fi-only unless overridden.
3. **Server retention of audio** it received as backup, versus audio that only ever lived on one device — should the server keep both indefinitely?
4. **Device naming.** Auto-derive from the Android model string, or prompt the user once? Auto-derived names leak hardware details into the UI of a shared server.
5. **Notebook size.** A long page of ink could make a change_log payload large. If pages grow past a few MB, per-notebook payloads should become per-stroke deltas — deferred until measured, not assumed.

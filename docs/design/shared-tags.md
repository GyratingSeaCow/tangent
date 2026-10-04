# Shared custom tags

One tag vocabulary for notebooks **and** recordings/notes. A tag is attached
from the row's ⋮ menu (notebook list row, notebook cover grid, recordings
list row) through one shared **Edit tags** sheet; long-press keeps its
existing multi-select meaning everywhere.

## Data model

| Side | Table | Notes |
|------|-------|-------|
| Client (Drift v33) | `tags(id, name, created_at, updated_at, sync_dirty, synced_seq)` | Names unique per device, case-insensitively; trimmed, inner whitespace collapsed, ≤ 48 chars. |
| Client | `tag_assignments(id, tag_id, target_type, target_id, created_at, sync_dirty, synced_seq)` | Polymorphic: `target_type` ∈ `notebook`, `dump`. UNIQUE(tag, type, target); indexes by target and by tag. No FK to targets (a trashed notebook keeps its tags for a restore). |
| Server | `tags`, `tag_assignments` | Same shape plus `deleted_at` tombstones and `origin_device_id`. CHECK on `target_type`. `CREATE … IF NOT EXISTS`; the `change_log` CHECK is rebuilt once to admit `tag` / `tag_assignment` (idempotent, preserves every row and the AUTOINCREMENT high-water mark). |

The v33 client step only creates the two tables (guarded by `sqlite_master`)
and their indexes; it runs from every supported schema including v3/v4 and
touches no existing row.

**Assignment id is derived**, not random: `ta-` + first 40 hex of
`sha256(tag_id NUL target_type NUL target_id)`. Two devices tagging the same
item with the same tag converge on one row. The server recomputes it and
rejects a mismatch; the same literal is pinned in a client and a server test.

## Sync

Two new entity types on the existing feed:

- `tag` upsert `{name, created_at, updated_at}` — pushed right after folders,
  before any target, so an assignment later in the batch resolves. Clean
  only when `updated_at` still equals the pushed value (a rename in flight
  stays dirty). A local unpushed rename or delete wins over a pulled upsert.
  Deletion is final on the server: an upsert for a tag it holds tombstoned
  (a device renamed it before pulling the deletion) is accepted, changes
  nothing, and is published as a delete — the pusher does not retry forever.
- `tag_assignment` upsert `{tag_id, target_type, target_id, created_at}` —
  pushed after all targets. Removal is a tombstone (`sync_tombstones`); a
  re-add before the removal pushed cancels that tombstone. A pulled removal
  spares a dirty local re-add. A pulled assignment whose tag is absent
  locally is dropped: the feed is seq-ordered, so the tag always lands
  first unless this device deleted it — and once that deletion has pushed,
  the server's delete is this device's own and never echoes back to clean
  up an orphan.
- **Deleting a tag** writes ONE `tag` tombstone. The server tombstones the
  tag's assignments in the same transaction; every client applying the tag
  delete drops all of that tag's assignments (notebooks and recordings,
  dirty or not). The UI asks once, and the copy says it removes the tag from
  every notebook and recording on all synced devices. The count it quotes
  covers only items visible here: live notebooks (not trashed) and existing
  recordings.
- An assignment upsert for a tag the server has never seen is rejected (stays
  dirty, retried). One for a tag already **deleted** is accepted, stored
  tombstoned and published as a delete — the deletion wins and the pushing
  device is not left retrying forever.

Older clients ignore both entity types (unknown types fall through), so the
change is additive on the wire.

## UI

- Rows: tags ride the title line as one ellipsized `#a #b` label capped at
  ~42 % of the width — never an extra line. Covers show it on the cover face.
- Filter: the same `TagFilterBar` (Tag · All / #name) on both lists, hidden
  while no tags exist. A filtered tag deleted elsewhere falls back to All.
  On both lists a tag filter change cancels selection. The recordings
  selection controller intersects with the filtered rows; the notebook list
  prunes its selection to the tag-filtered rows each build (a row that
  loses the tag mid-selection drops out). Bulk actions never touch a row
  the tag filter hides. (The notebook handwriting search still hides
  without deselecting — pre-existing, pinned behavior.)
- Screens watch projections only (`tagsProvider`: id + name;
  `tagLinksProvider(type)`: target id → tag ids), never full notebook/dump
  rows.

## Follow-ups (not built)

- Bulk tagging from the multi-select toolbars.
- Merging same-named tags created independently on two offline devices
  (they sync by id and stay separate, the folder precedent).
- Assignments of a permanently deleted recording are left in place (hidden,
  since no row renders them); a sweep could tombstone them.
- Tags in search, Ask retrieval, MCP tools and exports.

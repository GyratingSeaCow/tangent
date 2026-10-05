# To-do Kanban board

The Kanban board is a second projection of the existing to-do data, not a
separate task system. List and board views edit the same `todos` rows through
`TodoRepository`; the selected view is a local `SharedPreferences` setting.
`todo_columns` stores lane identity, name, order, soft-deletion state, and sync
metadata. Each to-do adds nullable `column_id` plus integer `board_order`.
List mode deliberately ignores those board-placement fields.

## Migration and sync

Client schema 34 creates `todo_columns` and adds the two placement fields.
During upgrade it inserts three stable default columns with an epoch timestamp,
assigns existing to-dos to **To Do**, gives them deterministic row order, and
marks formerly clean rows with local migration metadata. Pull may then install a
newer server body before sync re-applies and pushes only the owed placement.
Fresh defaults use the same merge-safe epoch stamp, so a remote rename or soft
delete wins. A fresh database seeds on the first to-do creation or first board
open. The server migration adds the matching table and fields and admits
`todo_column` to the change log. A stale last-write-wins acknowledgement carries
the canonical server row so the client does not clean a rejected local copy and
leave ghost content behind.

Columns sync as `todo_column` entities; `column_id` and `board_order` travel in
the existing `todo` payload. Column deletion is a synced soft delete. The fixed
default IDs let independently upgraded devices converge instead of creating
duplicate defaults.

## Interaction contract

- Pressing and holding a card for 200 ms starts the primary board move and
  reorder gesture. Ordinary vertical or horizontal swipes from a card scroll
  immediately. Insertion strips, full card bodies, and the full body of an
  empty lane accept drops.
- Board mode has no row selection or multi-select gesture. Card editing and
  deletion remain under the **⋮** action.
- The checkbox changes completion only. It never changes `column_id`, so a
  completed card remains in its current board lane. List mode may still render
  completed items in its existing Done section; that is a list projection, not
  a board move.
- Column **⋮** actions rename, move left/right, or delete the column. Columns can
  also be added from the board.

## Defaults and deletion

When there are no live columns, the repository inserts missing defaults **To
Do**, **In Progress**, and **Done**, in that order. Existing tombstones are never
resurrected; if all three fixed ids were retired, a new fallback lane preserves
the one-live-column invariant. New cards enter the first live column. Only null
placements are assigned when columns are ensured. Non-null unresolved references
remain untouched because their remote column may not have pulled yet.

The final live column cannot be deleted. Deleting any other column requires a
live destination; for a nonempty column all cards are moved to that destination
before the source column is soft-deleted, in one local transaction.

## Known constraints

- Board/list preference is device-local and is not synced.
- Board card movement is single-card only; bulk selection remains list-only.
- Ordering uses compact integer positions. It is not a sequence CRDT, so
  concurrent offline reorders use the existing sync conflict rules rather than
  preserving both users' orderings.
- The board is one horizontal scroller of fixed-width lanes. Each lane scrolls
  vertically within the available viewport; there is no compact lane layout.

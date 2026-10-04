# To-do Kanban board

The Kanban board is a second projection of the existing to-do data, not a
separate task system. List and board views edit the same `todos` rows through
`TodoRepository`; the selected view is a local `SharedPreferences` setting.
`todo_columns` stores lane identity, name, order, soft-deletion state, and sync
metadata. Each to-do adds nullable `column_id` plus integer `board_order`.
List mode deliberately ignores those board-placement fields.

## Migration and sync

Client schema 33 creates `todo_columns` and adds the two placement fields.
During upgrade it inserts three stable default columns, assigns existing to-dos
to **To Do**, gives them deterministic row order, and marks the affected rows
dirty so placement reaches other devices. A fresh database seeds on the first
to-do creation or first board open. The server migration adds the matching
table and fields and admits `todo_column` to the change log.

Columns sync as `todo_column` entities; `column_id` and `board_order` travel in
the existing `todo` payload. Column deletion is a synced soft delete. The fixed
default IDs let independently upgraded devices converge instead of creating
duplicate defaults.

## Interaction contract

- Direct card drag is the primary board move and reorder gesture.
- Board mode has no row long-press or multi-select. This avoids a gesture
  conflict with drag. Card editing and deletion remain under the **⋮** action.
- The checkbox changes completion only. It never changes `column_id`, so a
  completed card remains in its current board lane. List mode may still render
  completed items in its existing Done section; that is a list projection, not
  a board move.
- Column **⋮** actions rename, move left/right, or delete the column. Columns can
  also be added from the board.

## Defaults and deletion

When there are no live columns, the repository seeds **To Do**, **In Progress**,
and **Done**, in that order. New cards enter the first live column. Orphaned
card references are repaired to that column when columns are ensured.

The final live column cannot be deleted. Deleting any other column requires a
live destination; for a nonempty column all cards are moved to that destination
before the source column is soft-deleted, in one local transaction.

## Known constraints

- Board/list preference is device-local and is not synced.
- Board card movement is single-card only; bulk selection remains list-only.
- Ordering uses compact integer positions. It is not a sequence CRDT, so
  concurrent offline reorders use the existing sync conflict rules rather than
  preserving both users' orderings.
- The board is one horizontal scroller of fixed-width lanes; there is no
  compact layout or independent per-lane vertical scrolling.

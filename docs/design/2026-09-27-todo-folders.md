# To Do folders — design (2026-09-27)

Jeff: "we also need to add in folders in the to do list. Make it similar to
how the notebooks screen looks and allow you to long press or hit the three
dots on the right and select Move."

Follows `docs/design/2026-09-27-todo-section.md` (phase 1) and
`...-todo-voice-capture.md` (phase 2). Ships as **v1.24.0** — server +
client halves merge together (the wire contract lands atomically, same as
phase 1).

## Jeff's picks (recorded)

- **F1 Shared folders.** To-dos use the SAME `folders` table and rows as
  Recordings and Notebooks. A folder "Shop" holds recordings, notebooks and
  to-dos and appears on all three screens. No folder `kind`. Folder rows
  already sync; nothing new for folders on the wire.
- **F2 Folders outermost, like Notebooks.** One collapsible header per
  folder (alphabetical, case-insensitive), items inside sorted by due date
  (dated first ascending, undated after, then created order), each item
  carrying a small time chip (Overdue red / Today / date) where today's
  section headers used to convey it. `No folder` section last, omitted when
  empty. **One `Done` section at the bottom**, collapsed, across all
  folders. Flat list (no folder headers) when no folders exist — same rule
  as notebooks.
- **F3 App-wide gesture contract** (`references/list-screens-and-folders.md`):
  long-press on a row = **multi-select** with a toolbar offering
  Move / Mark done / Delete for the set; **⋮ on the row** = Move / Edit /
  Delete (ItemAction canonical order); ⋮ hides while selecting; tap toggles
  during selection; back exits selection first (`PopScope`). The date
  chip's long-press = clear due date **stays** (it is a chip, not the row).
  Folder headers long-press → the shared rename/delete sheet, never
  selection.

## Data

### Server (Ted)

- `todos.folder_id TEXT NULL` — plain `ALTER TABLE ADD COLUMN` (not part
  of the CHECK-constrained `change_log`, so no table rebuild). Idempotent
  migration guarded by `PRAGMA table_info`.
- `_apply_todo`: `folder_id` joins the nullable-field family with the
  **absent-vs-null sentinel** (absent = keep existing, explicit null =
  unfile). Value must be a string or null; NOT validated against `folders`
  (a folder deleted on another device must not reject the push — the
  client renders a vanished folder as unfiled, per the grouping rule).
- Pull payload includes `folder_id`. Older clients ignore it.
- Tests in `server/tests/test_todo_sync.py`: round-trip; absent preserves;
  explicit null clears; unknown folder id accepted; migration adds the
  column exactly once on a DB that already has `todos`.

### Client

- Drift `Todos.folderId` (`text().nullable()`), schema v23 → v24, migration
  `addColumn`. Push writes `'folder_id': row.folderId`; pull reads with the
  same `containsKey` sentinel as `due_date`/`source_ref`.
- `TodoRepository.moveToFolder(id, String? folderId)` and
  `moveManyToFolder(ids, folderId)` — bump `updated_at`, mark dirty.
- Deleting a folder unfiles its to-dos (existing `deleteFolder` path must
  clear `todos.folder_id` in the same transaction it clears notebooks/dumps;
  the confirmation copy already says contents are kept).

## UI

`client/lib/screens/todo/todo_list_screen.dart` — rewrite the list body:

- `todo_grouping.dart` (new, beside `dump_grouping.dart` /
  `notebook_grouping.dart`): same six rules typed for `TodoRow`; a row
  pointing at a vanished folder surfaces as unfiled. Done rows are pulled
  out BEFORE grouping into the trailing Done section.
- Section keys `todo-section-<folderId>` / `todo-section-unfiled` /
  `todo-section-done`; headers collapse on tap; header long-press →
  `showFolderHeaderActions` (existing widget, keys `folder-action-rename`
  etc.); `No folder` and `Done` headers have no actions.
- Row: checkbox · text · time chip (`todo-chip-<id>`, existing due-date
  chip; long-press clears) · **⋮** (`todo-menu-<id>`) → `showItemActionSheet`
  with `[ItemAction.move, ItemAction.rename (labelled Edit), ItemAction.delete]`.
  Move → `showFolderPicker` (existing, with "New folder…") →
  `moveToFolder`. Add `case` arms for the new enum use in any screen that
  switches exhaustively.
- Multi-select: long-press row (`todo-row-<id>`) → toolbar `× · N selected ·
  select-all · Move · Done · Delete` (keys `todo-select-move`,
  `todo-select-done`, `todo-select-delete`). Bulk delete confirms once,
  soft-deletes with one Undo snackbar for the set. Prune selection with
  `retainAll` each build. `PopScope(canPop: !_selecting …)`.
- Quick-add stays pinned at top; a new item lands **unfiled** unless a
  folder header is the only expanded one — no: keep it simple, new items
  are unfiled `[default]`; Move them after.
- Voice-captured items are unfiled.
- Search: none on this screen today; nothing to keep flat.

## Tests (client)

- `todo_grouping_test.dart`: the six rules + vanished-folder-as-unfiled +
  done-extracted-first + within-folder due-date order.
- `todo_list_screen_test.dart` additions: ⋮ → Move → picker → row moves
  sections; long-press → selection toolbar, ⋮ hidden, tap toggles, bulk
  Move moves all, bulk Done, bulk Delete confirms once + Undo restores
  all; back cancels selection (drive `handlePopRoute` on a PUSHED screen);
  folder header long-press opens rename sheet, not selection; date-chip
  long-press still clears the date. Mount with `FakeFoldersDb` +
  `foldersProvider` override + `SharedPreferences.setMockInitialValues`.
- `todo_sync_test.dart`: `folder_id` round-trip; absent key preserves.
- `todo_migration_test.dart`: v23 → v24 keeps rows, adds null folder_id.

## Sabotages (must each fail a named test)

- (a) Grouping drops rows whose folder vanished → grouping test fails.
- (b) `moveToFolder` forgets to bump `updated_at` → sync test: stale write
  dropped by the server-side newer-wins rule (round-trip test fails).
- (c) Push omits `folder_id` → round-trip test fails.
- (d) `canPop: true` → back-cancels-selection test fails.
- (e) Bulk delete hard-deletes → Undo-restores-all test fails.
- (f) Long-press on a folder header enters selection → header test fails.
- Server: absent `folder_id` clears the folder → preserve test fails;
  migration runs `ALTER` twice → duplicate-column test fails.

## Gates

Client: `flutter analyze` zero issues; full suite green (baseline
+2299 ~2). Server: pytest must not regress (554 passed, 3 skipped).
Device proof before tagging: create folder "Shop" from a to-do's Move on
the Fold → to-do appears under "Shop" on the S11 Ultra after sync, and
"Shop" also appears as a folder on the Notebooks screen (F1 proof).

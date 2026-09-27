# To Do section — multi-phase arc (starts v1.23.0)

Date: 2026-09-27 · Status: approved direction (Jeff's picks below); Phase 1
specced here, Phases 2-3 sketched and owed.

## Decisions (Jeff, 2026-09-27)

- **T1 — both.** A standalone list you add to by hand AND items flowing in
  from the app's existing todo-shaped sources (AI-summary action items,
  notebook checkbox blocks).
- **T2 — synced.** Todos are a first-class synced entity across all
  devices, like recordings and notebooks.
- **T3 — voice capture.** Record "pick up thermal paste, email the
  customer back" → checkable items.
- **T4 — due dates + Today/Upcoming split.** No reminders/notifications
  in this arc.

## Phasing (controller-decided; each phase is its own release train)

- **Phase 1 (THIS spec, v1.23.0):** synced `todo` entity + To Do screen +
  manual quick-add with due dates + home-screen entry.
- **Phase 2 (owed):** voice capture → items. Record from the To Do
  screen; transcript split into discrete items (summarizer env when
  installed, sentence/comma heuristic fallback); editable confirm list
  before anything lands.
- **Phase 3 (owed):** inflow. "Send to To Do" on AI-summary action items
  and notebook checkbox blocks, each item carrying a link back to its
  source (tap → opens the recording/notebook). One-way copy with
  provenance, NOT a live two-way mirror.

Phases 2-3 are recorded in docs/next-iteration.md when Phase 1 ships.

---

# Phase 1 spec (v1.23.0)

## What the user sees

- Home screen AppBar gains a checklist icon (`Icons.checklist`, tooltip
  'To Do', key `home-todo-button`) beside the existing dumps/notebooks
  icons → opens the To Do screen.
- **To Do screen** (`TodoListScreen`): quick-add field pinned at top
  ('Add a to-do…', submit adds instantly, field clears, keyboard stays
  up for chained entry). An optional calendar chip beside it sets a due
  date for the NEXT added item (date only, no time).
- Sections, in order, each with a count header, empty sections hidden:
  1. **Overdue** — due date before today (red-tinted date text)
  2. **Today** — due today
  3. **Upcoming** — dated, after today (grouped flat, date shown)
  4. **Someday** — no due date
  5. **Done** — collapsed by default, expandable; shows the latest 50
- Item row: leading checkbox (tap toggles, done rows strike-through and
  move to Done in the same frame), text (tap opens inline edit), due-date
  chip when dated (tap edits the date; long-press clears it), overflow ⋮
  with Delete (soft; no confirm — undo snackbar instead, 5 s).
- Checking an item stamps `done_at`; unchecking clears it. Nothing ever
  auto-deletes.

## Data model

New synced entity `todo`, device-authored (like notebooks), newer-wins on
`updated_at`, soft-deleted.

Fields (wire + both DBs):
- `id` TEXT PK (uuid v4)
- `text` TEXT NOT NULL
- `done_at` TEXT NULL (ISO instant; null = open)
- `due_date` TEXT NULL (ISO date `YYYY-MM-DD`, no time component)
- `source` TEXT NOT NULL DEFAULT 'manual' — enum-ish: `manual` now;
  `voice`, `summary`, `notebook` reserved for Phases 2-3
- `source_ref` TEXT NULL — reserved (dump id / notebook id + block id)
- `created_at`, `updated_at` TEXT NOT NULL (ISO instants)
- `deleted_at` TEXT NULL

## Server half (Ted)

- `todos` table + migration.
- `change_log.entity_type` gains `'todo'`: the CHECK constraint requires
  the **seq-preserving table-rebuild migration** — db.py already has the
  pattern from `ink_index`/`folder`; NEVER a bare ALTER.
- Sync: `/v1/sync/push` accepts `entity_type:'todo'` upserts/deletes from
  devices, applies newer-wins on `updated_at` (mirror the notebook/dump
  handling — read `_apply_document`/notebook apply first and follow the
  same absent-vs-null discipline for nullable fields: an older client's
  payload missing a key must not erase it). `/v1/sync/pull` fans todos
  out to every device with no opt-in flag (unlike ink_index — todos are
  small).
- Malformed todo payloads: reject per-entity the way other entities do;
  a bad todo must not poison the batch.
- No REST endpoints, no OpenAPI additions in Phase 1 — sync IS the API.
- Tests: migration (constraint rebuilt, seqs preserved — count and max
  seq before/after on a seeded change_log), push→stored→pull round trip,
  newer-wins drop of stale updates, absent-key tolerance, malformed 422
  or per-entity rejection per existing convention, soft delete fans out.

## Client half

- Drift `Todos` table mirroring the fields; **schemaVersion bump** with
  the usual ripple: grep `test/unit/data/` for the OLD version number —
  ~12 pins including the MULTILINE `PRAGMA user_version` one that
  single-line grep misses.
- `TodoRepository`: watch-all stream (sectioned in the UI layer), add,
  toggle, editText, setDueDate, softDelete, restore (for the undo
  snackbar). Every write stamps `updated_at` and marks the row dirty for
  push, following the notebook repository's shape.
- Sync engine: push dirty todos, apply pulled ones
  (`applyRemoteTodo` with the existing own-echo and newer-wins rules).
- `TodoListScreen` + `home-todo-button` per the UX section.
- Tests: repository real-SQL round trips (add/toggle/edit/date/delete/
  restore, never-set vs cleared due date distinguishable), sectioning
  rule unit tests (overdue/today/upcoming/someday boundaries around a
  fixed clock — swappable clock like `summary_pending.dart`), widget
  tests for quick-add (chained entry keeps keyboard), toggle moves rows,
  undo snackbar restores, done collapsed by default, home button
  navigates. Migration tests updated for the version bump.

## Sabotage (named, required)

- Server: (a) make apply ignore `updated_at` (last-write-wins) → the
  stale-update test fails; (b) bare-ALTER the constraint instead of
  rebuilding → the seq-preservation test fails.
- Client: (c) quick-add clears the field but drops the keyboard → the
  chained-entry test fails; (d) delete skips the undo window (hard
  delete) → the restore test fails.

## Proof before merge (device)

Two devices: add "buy thermal paste" due today on the S11 Ultra → sync →
appears under Today on the Fold; check it on the Fold → sync → Done on
the S11 Ultra. Screenshot both ends. Server log shows todo upserts
fanning out.

## Versioning / release

Server touched → all four version sites at release cut (client
pubspec, server version.py, docker-compose image tag, pyproject) +
DB backup before container redeploy + CHANGELOG. Version number decided
at merge time (v1.23.0 if page-backgrounds ships first as v1.22.0).

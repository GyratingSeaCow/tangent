# Internal links (wikilinks) — v1 spec

**Status:** approved scope (Jeff, 2026-10-02 chat). UX contract below is
literal; do not add inferred conditions.

## What

Select text anywhere text is shown → **Link** appears in the selection
toolbar → a picker sheet opens with three tabs across the top —
**Recordings | Meetings | Notebooks** — selectable, switching the list
below → choosing an item wraps the selected text as a link to it. The
link renders as a tappable colored span that navigates to the target.

Jeff's trigger description (2026-10-02): "if you highlight a word, press
and hold, it will bring up the option to click Link. At which point it
will take you into a pop up screen that has Dumps Meetings and Notebooks
attached to the top and are selectable and they make the page switch
between the items." (On-screen nouns follow the v1.22 rename: "dump" is
user-visible as "recording".)

## UX contract (literal)

1. **Everywhere, read-only AND editable text** (Jeff: "it should bring
   it up everywhere, read only and editable text"):
   - Notebook text blocks (editor).
   - Recording transcript — Edit mode (TextField) and read mode.
   - Text notes (compose and view).
   - Read-only transcript/text views gain selection support if they lack
     it (SelectionArea / SelectableText) so the toolbar can appear.
   - Exception (state it, don't silently skip): AI summaries and the
     Morning Brief are regenerated server-side; links placed there would
     be overwritten, so they offer no Link action.
2. On mobile, long-press already selects a word and shows the toolbar —
   that IS the press-and-hold path. Desktop: select + right-click /
   toolbar equally offers Link.
3. **Picker**: three tabs at the top — Recordings (brain dumps + text
   notes), Meetings (mode == meeting, incl. legacy ones), Notebooks.
   Tapping a tab switches the page/list. Search field filters the active
   tab. Lists reuse the data the normal list screens show (titles,
   newest first). Cancel = nothing changes.
4. Choosing a target replaces the selected text with a link token
   carrying the SAME display text (the selection), linked to the target.
5. **Rendering**: links show as a colored tappable span (TangentPalette
   select/lime family), raw token never visible at rest. Tap in read
   surfaces navigates: recording/meeting → recording detail; notebook →
   notebook editor. In an actively-editing TextField the span is styled
   but tap places the cursor (no navigation hijack while typing).
6. **Deleted target → quietly unwrap** (Jeff, 2026-10-02): the moment a
   target no longer exists locally, every surface renders the link as
   plain text (its display text), with no dead chip, no error. The
   stored token is rewritten to plain text lazily — next time that note
   or transcript is saved — never by a background sweep.
7. Links survive sync as plain text inside the existing fields; no new
   sync entity and no server change in v1. Backlinks ("Linked from…")
   are explicitly deferred to a follow-up spec.

## Token format

`[[dump:<id>|display text]]` and `[[notebook:<id>|display text]]`

- `dump:` covers all three modes (brain_dump, meeting, text_note) — the
  mode lives on the row, not in the token.
- Ids are the existing entity UUIDs; display text is arbitrary (no `]]`
  inside; escaping is NOT supported in v1 — the picker path can never
  produce it).
- Parsing is a single regex pass; malformed tokens render as the literal
  text they are (never crash, never half-render).
- Older builds simply show the raw token text (plain string in the same
  field) — acceptable degradation, no schema/DB version bump for the
  token itself.

## Implementation shape (client-only)

- `services/wikilinks.dart`: parse/serialize/unwrap (pure, heavily
  unit-tested): `parseWikilinks(text)`, `wrapSelection(...)`,
  `unwrapMissing(text, liveIds)` (returns rewritten text), plus a
  `WikilinkSpanBuilder` producing InlineSpans with tap callbacks.
- Custom `TextEditingController` override of `buildTextSpan` styles
  tokens inside editable fields (display text shown, token hidden is v2;
  v1 may show the styled full token while editing — at REST the rendered
  view shows only display text).
- Link action via `contextMenuBuilder` on the target fields +
  `SelectionArea` context menu on read surfaces.
- Picker: `widgets/link_picker_sheet.dart` — TabBar (3 tabs) + search +
  list, reusing dumps/notebooks providers; returns the chosen
  (type, id, title).
- Navigation via the existing routes (recording detail, notebook
  editor); target-exists lookup via the local Drift db (live rows only,
  deleted_at null ⇒ exists).
- Unwrap-on-save: any save path for a field that contains tokens runs
  `unwrapMissing` first.
- Keys: every new tappable element exposes `static const Key` members
  (repo test rule).

## Tests (TDD, non-negotiable)

- Unit: parser round-trip, malformed tokens, unwrapMissing rewrites only
  dead ids, wrapSelection on sub-word/multi-word selections.
- Widget: Link appears in the toolbar on the enumerated surfaces (and
  NOT on summaries); picker tabs switch lists and search filters; pick
  wraps selection; rendered span taps navigate (recording + notebook);
  deleted target renders plain and saving rewrites the text; editing
  with a token keeps cursor behavior sane.
- Settings overrides per the HomeScreen welcome-dialog rule where
  screens are mounted.

## Non-goals (v1)

- No backlinks panel (follow-up spec will add `note_links` server-side).
- No autocompletion (`[[` typing shortcut), no link renaming UI, no
  link-to-folder/todo, no escaping syntax.

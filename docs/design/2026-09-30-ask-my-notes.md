# Ask My Notes — design spec (v1.37.0)

Date: 2026-09-30. Decisions made by Jeff via design forks, this session.
Research origin: the single most recurring community ask across r/selfhosted,
r/PKMS, r/GenAiApps and competitor wish-lists — "an app that actually
remembers what you said," NotebookLM-style Q&A, but private and self-hosted.

## What Jeff sees

A fourth top-level destination: **Ask** (icon next to Recordings /
Notebooks / To Do). It is a chat:

- Ask a question by **typing or by voice** — a mic button records, the
  existing transcription pipeline transcribes it, and the transcribed text
  is submitted as the question in one motion.
- The answer appears as a chat bubble, **citing the sources it drew
  from** — each citation is a tappable chip (recording title · date;
  notebook page; To Do). Tapping a recording citation opens it **at the
  matching transcript moment** (reuse the search → `initialSeekSeconds`
  plumbing). Notebook citations open the page; To Do citations open the
  To Do section.
- **History is kept and synced** — the same conversation thread shows on
  every device (server-side storage, rides the sync feed like other
  entities). Scroll back through everything ever asked.
- If the server is unreachable: the question is refused with the standard
  named-server error pattern (same as summaries) — no queueing of
  questions in v1.

## What it can see (Jeff: "everything")

- Recording transcripts (raw + speaker names via the name map)
- Meeting summaries / AI notes
- Notebook text: typed blocks AND handwriting OCR text (ink_index)
- To Dos (title, done state, due date)

## Answering shape (server)

New endpoint `POST /v1/ask` (bearer, per-device like everything else):

1. **Retrieve**: FTS5 across the four corpora (transcripts, summaries,
   notebook/ink text, todos) + recency weighting. Top-K chunks with
   entity ids and, for transcripts, word-timing offsets for deep links.
2. **Answer**: the existing llama.cpp summarizer model composes a grounded
   answer from the retrieved chunks ONLY (prompt forbids outside
   knowledge; "I couldn't find that in your notes" is the honest miss).
3. **Cite**: response carries the source list (entity type, id, snippet,
   seek seconds where applicable) — the client renders these as chips.
4. Ask turns are stored server-side (`ask_messages` table: id, role,
   text, sources_json, created_at) and served over the sync feed.

No embeddings/vector DB in v1 — FTS + recency gets Jeff's corpus size
excellent answers today; an embedding upgrade is a drop-in later if misses
show up. (Decision: keep v1 dependency-free and honest about misses.)

## Explicitly out of v1

- No cross-question memory in answers (each question retrieves fresh; the
  thread is history, not context) — revisit after real use.
- No question queueing while offline.
- No answer streaming (summaries don't stream either; consistency).

## Queued behind this arc (order fixed by Jeff)

1. **Pinnable items** — pin recordings / notebooks / To Dos. REVISED by
   Jeff (2026-09-30, in build): a pinned item sorts to the top of **its
   own category/folder group**, NOT a global pinned section at the top
   of the page. Long-press → Pin per the list-screen contract, synced,
   pin indicator on the row.
2. **Morning review** — REVISED by Jeff (2026-09-30, in build): Settings
   → Reminders gets a **toggle to enable/disable** morning review plus a
   **time picker** (default 8:00). When enabled, at the set time: a
   notification AND a light-blue card at the top of Home that stays
   until viewed, then tucks away. Contents v1: **yesterday's captures
   only** (recordings + notes, one-line summaries). Light blue =
   start-of-day signal; "presented beautifully" is a design
   requirement, not decoration. Toggle off = no notification, no card.
3. **Auto-file** — after transcription the server picks the best matching
   EXISTING folder; when confident, files it and the card shows
   "Auto-filed to <folder> · Undo"; when not confident, does nothing
   (no chip, zero noise). Folders stay the only organizing concept.

## Standing decisions honored

- #11 parked (dirty-push name-map clobber) — do not build on speaker_names
  sync semantics in this arc without checking it.
- No Bluetooth-mic recording work (Jeff: "it doesn't work well").
- Audio import already exists — do not rebuild.

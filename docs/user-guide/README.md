# Tangent user guide

Screenshots from a Galaxy Fold running Tangent v1.43.0, Anodized (dark)
theme. On every top-level screen a six-key rail sits under the app bar:
**Capture · Recordings · Notebooks · To Do · Ask · Settings**. The rail is a
jump bar, not a tab stack — Android Back always walks out through Capture.
Long-press is the universal "act on this item" gesture.

## Capture

![Capture screen](capture.png)

| Control | Function |
|---|---|
| **Import audio** (note icon, app bar) | Import an existing audio file as a recording; it joins the transcription queue like a native capture. |
| **Sync now** (circular arrows, app bar) | Push/pull all synced data with the paired server immediately. Auto-sync also runs on changes; this forces a pass. |
| **Sun icon** (app bar) | Reopen today's morning review. Only shown while the Reminders toggle is on. |
| **State eyebrow** | READY TO RECORD / RECORDING / TEXT NOTE — the screen's current mode, always visible above the timer. |
| **Timer** | Elapsed recording time; stays 00:00 until recording starts. |
| **Red mic button** | Start recording in the selected capture mode. While recording it becomes the stop control and a live waveform renders. |
| **Brain Dump / Meeting / Text Note** | Capture mode selector. Brain Dump = voice memo with verbatim transcript; Meeting = speaker-aware transcript + meeting notes; Text Note = typed note, no audio. The caption under the selector describes the active mode. |
| **Lime + key** (bottom right) | Create sheet — routes to the same create flows as each list screen's Add. |

## Recordings

![Recordings screen](recordings.png)

| Control | Function |
|---|---|
| **← Back** (app bar) | Back to Capture. |
| **Sync now** (app bar) | Same forced sync pass as on Capture. |
| **Search** (app bar) | Full-text search across titles and transcripts; results show match snippets. |
| **Mode · All** chip | Filter by capture mode (Brain Dump / Meeting / Text Note). Applies after search — an active chip can hide search hits. |
| **Transcript · All** chip | Filter by transcription state (transcribed / pending / failed). |
| **Folder heads** (Bugs, Personal, …) | Tap to collapse/expand a folder. The number on the right is the folder's recording count. |
| **Recording rows** | Tap to open the recording detail (playback, transcript, summary). The badge shows transcription status; the bar graphic marks audio present. Long-press to select, then bulk actions appear in the toolbar: select all, download audio, transcribe, send to notebook, delete. |
| **Lime + key** | Add — create/import into Recordings. |

## Notebooks

![Notebooks screen](notebooks.png)

| Control | Function |
|---|---|
| **Search notebooks** (app bar) | Filter notebooks by name. |
| **Sync now** (app bar) | Forced sync pass. |
| **Covers/list toggle** (grid icon, app bar) | Switch between list rows and cover-art grid. |
| **Folder heads** | Collapse/expand a folder of notebooks. |
| **Notebook rows** | Tap to open the notebook editor (handwriting with pen styles and palm rejection, typed blocks, embedded recording cards, lasso selection, multi-step undo/redo). The ⋮ menu holds per-notebook actions (rename, move, delete, pin). |
| **Lime + key** | Create a new notebook. |

## Notebook editor

![Notebook editor](notebook-editor.png)

Opens from any notebook row. The Back arrow **saves and exits** — there is no
discard dialog; only a failed save keeps the screen open (with a snackbar
saying why).

| Control | Function |
|---|---|
| **Title field** (app bar) | Rename the notebook in place. |
| **Find in notebook** (magnifier) | Search handwriting and typed blocks; next/previous walk the matches on your real ink. |
| **Save notebook** (disk) | Save immediately (Back also saves). |
| **Notebook menu** (⋮) | Page settings (background/ruling), export, and other notebook-level actions. |
| **Toolbar row** | One permanent row: Draw toggle, highlighter, eraser, pen nib, lasso, Undo stroke, Redo, and the pen-size slider. Tapping any tool enters draw mode with that tool active. **Long-press the pen or highlighter to open its colour palette** — each tool remembers its colour and tints its icon to match. |
| **Draw mode off** (default) | A finger drags/scrolls the page; only the stylus inks (palm rejection). Toggle Draw to ink with a finger. |
| **Lasso** | Loop ink or blocks to select (a loop catching ~40% of an item grabs it), then drag to move or delete the selection. |
| **Insert** (bottom bar) | Add content blocks: typed text, checkboxes, images, embedded recording cards. |

## To Do

![To Do screen](todo.png)

| Control | Function |
|---|---|
| **Sync now** (app bar) | Forced sync pass. |
| **Add a to-do…** field | Type and submit to create a task directly. |
| **Due** (calendar button) | Attach a due date to the task being added; due tasks surface in the morning review and reminders. |
| **Folder rows** | Collapse/expand task folders; the count is open tasks inside. |
| **Done (n)** | Collapsed section of completed tasks. |
| **Task rows** (inside folders) | Tap the checkbox to complete. Long-press to select for bulk actions: select all, move to folder, mark done, delete. |
| **Lime + key** | Create sheet (new to-do, with folder/due options). |

## Ask

![Ask screen](ask.png)

| Control | Function |
|---|---|
| **Question bubbles** (lime) | Your questions. Answers are grounded in your recordings, summaries, notebooks and to-dos — no outside knowledge. |
| **Source chips** (under an answer) | The exact items the answer drew from, with timestamps into each recording. Tap a chip to open the item at that spot. Long-press to act on the underlying item: move, rename, delete, pin/unpin. |
| **Ask your notes…** field | Type a question. |
| **Mic button** | Dictate the question instead of typing. |
| **Send (Ask)** | Submit the question. |

## Settings

![Settings screen](settings.png)

Nine categories, each opening an in-place drill. **SAVE** (app bar) writes
every changed setting across all categories at once.

| Category | Contents |
|---|---|
| **Storage** | Default recordings folder (SAF grant), local storage use, Wi-Fi-only upload. |
| **Import & export** | Bulk audio import/export, Obsidian Markdown export. |
| **Recording input** | Microphone selection, Bluetooth input, gain, record trigger. |
| **Server & devices** | Server connection, device pairing, pairing-code display, trash, welcome-message toggle. |
| **Transcription** | Whisper model selection, custom vocabulary. |
| **Intelligence** | Handwriting search (OCR), AI summaries, auto-file. |
| **Integrations** | Google Tasks sync, remembered voices (speaker naming). |
| **Reminders** | Due-date reminders, morning review toggle, completion notices. |
| **Maintenance & about** | Diagnostics, licenses, version. |

## Morning review

![Morning review](morning-review.png)

Opens automatically over Capture once per day (when Reminders are on), or
any time from the sun icon. Shows every one of yesterday's captures, today's
due to-dos with overdue items in their own section, and pinned items; with
AI summaries installed, a generated daily brief renders at the top.

| Control | Function |
|---|---|
| **✕** (top right) | Dismiss the review for today. |
| **Rows** | Tap any capture/to-do to open it. |

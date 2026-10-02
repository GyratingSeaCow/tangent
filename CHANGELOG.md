# Changelog

All notable changes to Tangent.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.45.0 — 2026-10-02

### Changed

- Welcome dialog dismissal contract (spec correction): the pairing
  walkthrough now repeats at EVERY launch — paired or not — and the ONLY
  way to remove it is checking "DO NOT REMIND ME AGAIN" and pressing the
  new Confirm button (disabled until the box is checked; the checkbox
  alone persists nothing). Close remains this-launch-only. Settings →
  Server & devices → "Show welcome message" is now one-way: it re-arms
  the message, but flipping it off is ignored and the switch snaps back.
- Container audit: image now builds CPU-only by default (14.3 GB → 2.9 GB;
  `docker-compose.gpu.yml` sets the new `TANGENT_GPU=1` build arg to restore
  the CUDA torch + cu12 runtime flavour), runs as non-root uid 1000 (Linux
  hosts upgrading: `sudo chown -R 1000:1000 ./data` once), drops curl for a
  Python-stdlib healthcheck, pins the base image and uv, applies Debian
  security updates at build, upgrades CVE-flagged wheel/jaraco.context, and
  persists the HF/pyannote model cache under `/data`. Compose adds
  `no-new-privileges`, `cap_drop: ALL`, and `init: true`.

## 1.44.0 — 2026-10-01

### Added

- First-run welcome dialog: pairing walkthrough (server start, setup token,
  Find my server, 6-digit code) repeats at every launch until this device is
  paired. The bottom-centre "DO NOT REMIND ME AGAIN" checkbox dismisses it
  forever; Settings → Server & devices → "Show welcome message" turns it
  back on. Closing without checking reminds again next launch.

## 1.43.0 — 2026-10-01

### Added
- **Morning Brief.** With AI summaries installed and enabled, the server
  pre-generates a short daily brief (a narrative paragraph plus bullet
  highlights) around 05:00 server-local from yesterday's captures, today's
  due To Dos and pinned items. It is cached per day, regenerated only on
  explicit request, and served at `GET /v1/morning-brief`. The morning
  review renders it as read-only markdown at the top of the screen. When
  the summarizer is not installed, or the day's brief is not generated
  yet, the section is hidden entirely — the review never waits on it.

### Fixed
- Ask delete holds its deletion lease across the server DELETE, so a sync
  pull can no longer resurrect the item mid-deletion.
## 1.42.1 — 2026-10-01

### Fixed
- **No more Capture flash when jumping between screens.** Tapping a rail key
  from a list screen used to pop to Capture first and then push the new
  screen, so Capture showed for the length of the transition. The jump is now
  one navigator transaction: the screen you were on stays beneath the
  transition until the new one has landed. Back still walks out through
  Capture.
## 1.42.0 — 2026-10-01

### Changed
- **Instrument Console look.** A UI-only restyle: every button, action, menu
  entry, setting and flow from 1.40.0 behaves exactly as before.
  - A six-key navigation rail (Capture, Recordings, Notebooks, To Do, Ask,
    Settings) sits under the app bar on every top-level screen. It is a jump
    bar, not a tab stack: Android back still walks out through Capture.
  - One lime **create** key on Notebooks and To Do opens a sheet that routes
    to the same create flows as before. Recordings keeps its own Add key.
    Red stays reserved for recording and destruction.
  - Capture shows a state eyebrow (READY TO RECORD / RECORDING / TEXT NOTE),
    a large tabular timer and a lime live waveform; import audio moved into
    the app bar.
  - Settings is organised into nine categories (Storage, Import & export,
    Recording input, Server & devices, Transcription, Intelligence,
    Integrations, Reminders, Maintenance & about). Every control is where it
    was, one tap deeper; SAVE still saves everything.
  - Corners are 6px panels / 8px sheet tops; folder heads are inset cards;
    sheets carry a drag handle; the editor's mode tools light up in pills.
  - Wide screens (Fold open, tablets): reading surfaces (Capture, Ask,
    Settings, recording detail) are centred at a 700dp measure; list roots
    use the full width. The rail compresses instead of overflowing at 280dp
    split-screen widths.
## 1.41.0 — 2026-10-01

### Changed
- **New look: Instrument.** The whole app moves from the Blackout palette to the Instrument design language — a field-recorder chassis in two finishes: **Anodized** (dark, the default) and **Aluminium** (light), following the system setting. The select colour is now **#C4EC42 lime** in both themes, with text and icons on lime always near-black; the record/delete colour is **#FF4F1F**; and everything carries a small radius on the approved 4/8/12/18 scale — tags and checkboxes 4, keys/buttons/inputs/rows 8, panels and cards 12, sheets and dialogs 18. No more pills, no more stadium chips.
- Theme-aware colours are exposed to widgets as a `TangentPalette` ThemeExtension (`TangentPalette.of(context)`); the legacy `TangentColors` statics remain, remapped to Anodized, while screens migrate.
- Error text no longer renders red on lime surfaces — the Instrument hot colour measures ~2.4:1 on lime, so content on a lime fill always uses the dark on-colour.
- Notebook ruling and handwriting ink nudged to the Instrument warm greys (ruling `#615E56`, ~2.9:1 against the page; ink `#F2EFE6`).

## 1.40.0 — 2026-10-01

### Added
- **Act on Ask sources directly.** Long-press any source chip under an Ask
  answer — recording, notebook or To Do — to move, rename, delete, or
  pin/unpin the underlying item. Pins made from Ask show up everywhere the
  item lives (Recordings, Notebooks, To Dos). Deleting is fail-safe: a
  recording that has ever attempted an upload is never removed locally on a
  server miss, and items busy transcribing refuse deletion cleanly.
- **Morning review is now a full screen.** The daybreak-blue review takes
  over the whole screen with every one of yesterday's captures (no more
  5-item cap), today's due To Dos with overdue items in their own section,
  and your pinned items. It auto-opens on the first launch of the day and
  can be reopened anytime from the new sun icon next to Settings on Home —
  both appear only while morning reviews are enabled in Settings.

### Changed
- **Ask opens on your latest message** and reads newest-backwards, staying
  pinned to new answers as they arrive.
- **Your Ask questions now sit in signal-green bubbles**, visually distinct
  from Tangent's answers.
- The morning review Home card is replaced by the full-screen review.

### Fixed
- The morning review no longer tints the Android navigation bar daybreak
  blue across the whole app; its styling is scoped to its own screen.

## 1.39.0 — 2026-10-01

### Added
- **Pin what matters — recordings, notebooks and To Dos.** Long-press any recording, notebook or To Do (or use its action sheet) and pin it: the item sorts to the top of its own category or folder group — no separate global section — wears a pin indicator on its row, and the pin syncs to every paired device. Drift v30. Spec `docs/design/2026-09-30-ask-my-notes.md` (queued item #1).
- **Morning review — yesterday, waiting for you at breakfast.** Settings → Reminders gains a Morning review toggle (default off) with a time picker (default 8:00 AM). At the set time: a notification and a light-blue daybreak card at the top of Home listing yesterday's recordings and notes (one-line summaries, up to 5, then "and N more"). The card stays — across restarts — until viewed (tap an item, "and N more", or the check), then tucks away. Nothing captured yesterday means no notification and no card; toggle off means silence. Client-only, no schema change. Spec `docs/design/2026-09-30-ask-my-notes.md` (queued item #2).

## 1.38.0 — 2026-09-30

### Added
- **Auto-file — a new recording finds its own folder.** After transcription the server picks the best matching *existing* folder for the capture; when it's confident the capture is filed and its card shows an **Auto-filed to ‹folder› · Undo** chip on every paired device — Undo quietly puts it back where it was. When it's unsure, nothing happens: no chip, no noise, and folders are never created. Matching is dependency-free TF-IDF against each folder's own content (accept 0.22 cosine with a 0.08 best-vs-runner-up margin and 3+ shared terms, calibrated like voice matching), and a capture you've already filed is never second-guessed. Settings → **Auto-file** turns it off (default on, stored on the server like the AI-summaries auto-trigger). Spec `docs/design/2026-09-30-ask-my-notes.md` (queued item #3).
- **Filing a Brain Dump into a folder now syncs to every paired device** — filing used to be per-device only. Drift v29 with a one-time backfill that re-pushes existing filings and shields them from the first post-upgrade pull.

### Fixed
- An Ask answer that admits "I couldn't find that in your notes" no longer lists sources: an honest miss now ships zero citations, in both the response and the synced answer history, instead of up to 8 chips that contradicted it.

## 1.37.0 — 2026-09-30

### Added
- **Ask My Notes.** A new **Ask** destination: ask a question in text or by voice and get an answer grounded in your own recordings, summaries, notebooks, and to-dos. Answers cite their sources as tappable chips — a cited recording opens seeked to the exact moment that backs the answer; honest misses say so instead of guessing. Question/answer history syncs read-only to every paired device (Drift v27, pull-only). Spec `docs/design/2026-09-30-ask-my-notes.md`.
- **Voice questions under 25 seconds are asked and then fully discarded** — transcribed, submitted, and removed from the library, the server (authoritative delete + tombstone), and local storage (SAF-aware). Questions 25 s and longer persist as normal recordings.

### Fixed
- Retrieval recency no longer misranks notebooks: notebook timestamps sync in milliseconds and the server assumed seconds, so a years-old notebook could outrank yesterday's recording.
- A deleted recording can no longer be resurrected by a transcription/summarize job finishing after the delete (the server no longer publishes sync upserts for deleted recordings).
- The Ask screen recovers after a successful voice question (busy spinner previously never cleared), maps server errors to real guidance (409 → install AI summaries) instead of a generic failure, retries the post-ask sync pull when a sync is already running, and surfaces incomplete local cleanup instead of silently keeping audio.

## 1.36.1 — 2026-09-30

### Fixed
- **Google Calendar sync no longer fails with "Invalid time zone definition" on Linux.** flutter_timezone has no Linux implementation, so events captured on Linux stored an OS abbreviation ("EDT") instead of an IANA name and Google rejected every push with a 400 — Retry could never succeed because the bad zone was stored on the event. The client now resolves the IANA zone from `$TZ` or the `/etc/localtime` symlink, and the server sanitizes legacy abbreviation rows at push time (EDT → America/New_York, unknown → UTC), so events captured by old clients sync without manual repair.
- Recording on the Linux AppImage no longer dies at the encode step: bundled libva from the ffmpeg dependency closure shadowed the system libva that the spawned system `ffmpeg` needed (`vaMapBuffer2` symbol lookup error). libva/libvdpau are now excluded from the bundle and resolve from the host.
- A calendar push that fails partway no longer misreports the number of events already pushed.
- Leaving the recordings list now clears its search, so coming back doesn't show a stale filter.

## 1.36.0 — 2026-09-30

### Added
- **Voice matching — Tangent learns who's speaking.** (community request #4) Rename *Speaker 1* to a person once and the server remembers their voice; the next recording they're in comes back already named. One voice book on the server (works from every device), silent auto-naming only when you haven't named anyone on that recording yourself, and a per-person **Forget** in Settings → Voices — no wipe-all. Spec `docs/design/2026-09-29-voice-matching.md`.
- **Brain Dumps over 30 seconds now get speaker sections** (`## Speaker N`) and the Name-speakers flow, exactly like Meetings — so voice matching works there too. Short dumps (≤ 30 s) stay plain text.
- Settings → **Voices**: the names the server knows, each with sample count and Forget.

### Changed
- Matching thresholds are calibrated on real recordings (accept 0.60 cosine with a best-vs-second margin, minimum 15 s of summed speech per speaker before a voice is matched or taught — short snippets are too unreliable to trust).
- Correcting a name (rename or clear) now *un-teaches* the old name exactly: the voice book stores unnormalised sums with a per-recording provenance ledger, so only samples you actually taught are ever removed, removal is mathematically exact, and the auto-matcher's own guesses can never poison a stored voice. Forgetting a voice also clears its ledger.

### Fixed
- Meeting transcripts stopped losing their speaker embeddings on real recordings (the diarization output was read from the wrong layer, so voice data was silently empty).
- Near-silent recordings can no longer poison a stored voice with NaN centroids; invalid stored rows are skipped loudly instead of corrupting a push.
- "Name speakers" no longer disappears from the ⋮ menu after tapping into the transcript editor.

## 1.35.0 — 2026-09-28

### Added
- **Voice → Google Calendar events.** "Add this to my calendar dentist Thursday at 2" (and "add X to my calendar", "put this/that on my calendar", "calendar this") in a Brain Dump or Meeting creates the event on your primary Google Calendar on the server's next Google tick. Date + time → one-hour timed event; date only → all-day. Spoken times are parsed for the first time ("at 3", "3:30 pm", "noon", "at 15:00", "3 o'clock", "seven in the morning"). The recording gets an **Added to your calendar** card — each row opens the Google event, shows *· syncing…* until the server has pushed it, and Undo removes them from Google too. Edits made on Google flow back (title/date/time, deletion). Spec `docs/design/2026-09-28-voice-calendar-events.md`.
- **No-date rule (Brain Dump only).** "Add this to my calendar renew the passport" in a Brain Dump lands on the recording's day flagged *today (no date said) — tap to fix*; in a Meeting a date-less phrase is skipped because it is said conversationally there. A time with no date is today at that time, flagged.
- **Meeting capture is back** in the home picker (Brain Dump · Meeting · Text Note) and the recordings list's create menu — it had been removed from capture in v1.22.0. Meeting notes, action items and the rendering never left.
- Settings → Google shows a **Calendar:** line: *not enabled — tap Reconnect* when the stored token predates the calendar scope, otherwise *connected · N events last sync*.

### Changed
- Google OAuth now requests `calendar.events.owned` alongside Tasks. Existing links keep working for Tasks; one **Reconnect** grants the calendar half. Enable the Google Calendar API in your Cloud project first.
- Server: new `calendar_events` entity on the sync feed (`google_event_id` / `google_html_link` / `google_updated` are server-authored and never accepted from a device); `google_tasks_link` gains `granted_scope`, `calendar_sync_token` and the last-cycle calendar counters. Update the server image with this release.
- Client database v26 (`calendar_events` table). The spoken-date grammar moved to `voice_date_grammar.dart`, shared by To Do and calendar capture — To Do parsing is byte-identical.

### Security
- Server: audio paths are confined to validated entity ids (`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` on `DumpCreate.id`, `SyncChange.entity_id` and every path parameter, plus a containment assert) — closes the CodeQL `py/path-injection` findings in `dumps.py`.
- CI: least-privilege `GITHUB_TOKEN` per workflow/job, CodeQL (actions + python), Dependabot version updates, release-tag protection ruleset.

## 1.34.0 — 2026-09-28

### Fixed
- **Unreachable server is named, not spun on.** A recording whose upload/transcription has been retrying a server that never answers for 45 s now says so on its progress panel — `Can't reach the server at <address> — still retrying` — and, when that address is a Wi-Fi one (192.168.x.x / 10.x / 172.16-31.x), tells you the fix: Settings → Server → the server's Tailscale address. Retries continue underneath; nothing is marked failed. (Jeff's cellular upload spun for an hour with the app paired to the LAN address.)
- **Connection screen says which address works where.** A standing hint under Find my server: found (Wi-Fi) addresses only work on that network; enter the Tailscale address (http://100.x.x.x:8765) to use Tangent away from home. On cellular the scan error names that fix instead of just 'No local network found'. The URL field hint shows both shapes, labelled.
- **README pairing rewritten as two options** — Tailscale (works everywhere) and LAN (home only) — with the spin-forever symptom called out and the Windows firewall rule for port 8765 (Docker's LAN rule does not cover the Tailscale interface).

## 1.33.1 — 2026-09-28

### Changed
- Completion notifications now post even while you are looking at that recording. The first live run had the transcription finish on-screen and the shade stay silent, which read as the feature not working; the screen shows the text, the shade pings.

## 1.33.0 — 2026-09-28

### Added
- **Completion notifications.** The shade now announces the result, not just the work: `Transcribed · <title>` when a transcription finishes (or `Transcription failed · <title>`), and `Notes ready · <title>` when the AI summary this device asked for lands. One slot each (ids 1002/1003) — a burst of recordings replaces the notice rather than stacking ten. Tapping opens that recording (`tangent://dump/<id>`, cold or warm), and the notice is skipped when you are already looking at it. Desktop gets the same via the reminder toast path.
- Settings → Reminders: **Completion notifications** switch (default on).

## 1.32.0 — 2026-09-28

### Added
- **Regenerate notes now uses the AI summarizer** when your server has it
  installed (Meeting template); otherwise the quick extractor as before.
  The card tells you which one ran.
- **Word-level timestamps in Markdown export** (Settings → Obsidian):
  `word⁽ᵐᵐ:ˢˢ⁾` on the first and every tenth word. Off by default — off is
  byte-identical to before.
- Recordings whose speaker headings could not be safely renamed by the
  1.17 upgrade are listed once on Home so you can name the speakers again.

### Changed
- Meeting-notes digests use your speaker names, not “Speaker 1”.
- Notebook text stamps stay attached to their words when you edit text
  before them, instead of being dropped.

### Fixed
- CI on Linux: the SQLite busy-timeout guard no longer depends on how long
  SQLite sleeps (the app was never affected).
## 1.31.1 — 2026-09-28

### Changed
- **Record widget in the app icon's colours** — black tile, lime mic,
  purple dot — instead of the red button. Same for the Record shortcut.

### Removed
- The "Hey Google, start recording in Tangent" action. Assistant only
  carries out an app's voice actions once the app is on the Play Store;
  installed directly, it announced the recording and never started one.
  Better no voice path than a fake one.
## 1.31.0 — 2026-09-28

### Added
- **Record without opening the app.** A 1×1 home-screen widget (the red
  mic from the main screen) starts a brain dump the moment you tap it;
  tap again to stop. Works from the lock screen. Long-press the app icon
  for the same 'Record' shortcut.
- **"Hey Google, start recording in Tangent."** Google Assistant can start
  (and stop) a recording. Give it a launch or two after installing to
  learn the phrase.
## 1.30.0 — 2026-09-28

### Added
- **Folders are Google lists.** Every Tangent folder now has its own list
  in Google Tasks with the same name; unfiled to-dos stay in "Tangent".
  Move a task in Tangent and it moves in Google; drag it between lists in
  Google and it changes folders in Tangent. Deleting a folder empties and
  removes its Google list. Lists you create in Google stay Google-only.
- **Sync button on To Do pushes to Google right away** — the snackbar
  says *Synced · Google updated* instead of waiting for the five-minute
  worker.
- Settings → Google Tasks shows which lists are mapped.
## 1.29.1 — 2026-09-27

### Fixed
- **"Recording failed: database is locked"** on Android. The daily
  reminder and background sync open the app's database from their own
  workers; when one overlapped a recording the other gave up instantly.
  Every connection now waits its turn (up to 5 s) instead of failing, and
  the database runs in WAL mode so readers never block the writer.
## 1.29.0 — 2026-09-27

### Added
- **Morning reminder on the desktop** (Linux and Windows). Same digest as
  the phone, as a system notification; click it to open To Do. If the PC
  was off at the time, the first launch that day shows it marked
  *Missed 7:00*.
- **More ways to say when.** "call mom tomorrow at 3 pm" keeps the time in
  the item and files it under tomorrow; "this weekend" is Saturday; "on
  the 15th" is the next 15th; "a week from Friday"; "tonight" and "this
  afternoon" mean today.
- **Sync button on the To Do page**, same as Recordings and Notebooks.
- Client-only; version kept uniform.
## 1.28.1 — 2026-09-27

### Fixed
- The duplicate healer in 1.28.0 only looked at to-dos as they arrived, so
  pairs that were already on every device were never touched. Each sync
  now sweeps them too; the older copy stays.
## 1.28.0 — 2026-09-27

### Added
- **Morning reminder** (Android). Settings → Reminders: one notification
  at the time you pick (7:00 am by default) listing what's due today and
  how many items are overdue; nothing is sent on a clear day. Tap it to
  open To Do. Off until you turn it on.

### Fixed
- **Re-transcribing a recording no longer loses or doubles its to-dos.** A
  changed transcript adds the new items and keeps the ones you already
  have (and anything you edited); an item you deleted stays deleted.
- **Duplicate voice to-dos from two devices heal themselves** on the next
  sync — the older copy wins, the other is removed.
- Client-only; version kept uniform.
## 1.27.0 — 2026-09-27

### Added
- **Say it like you mean it.** Voice to-dos now understand *tomorrow*,
  *Friday*, *next week*, *in three days*, *end of the month*, and friends
  — and each item can carry its own date: "for Friday: buy milk, and call
  mom on Sunday" files milk under Fri and mom under Sun. A weekday said on
  that same weekday means next week's; "next week" is Monday; "next
  month" is the 1st. Words that merely look like dates (*sun* screen,
  *may* call, *mon* ami) are left alone.
- Client-only; version kept uniform.
## 1.26.0 — 2026-09-27

### Added
- **Spoken due dates.** "Add to my to-do list for September 30th to go to the
  store" now creates *go to the store* due Sep 30 — the date phrase at the
  front applies to every item in that sentence and no longer clutters the
  text. Month and day ("Sept 30", "the 30th of September", "9/30"),
  optional year; without a year it is the next such date after the
  recording, never one in the past. Impossible dates are left as text.
  Due dates flow to Google Tasks like any other.
- Client-only; server stays functionally at 1.25.1 (version number kept
  uniform).
## 1.25.1 — 2026-09-27

### Fixed
- **Google sign-in actually completes.** Google only accepts a loopback
  redirect (`http://127.0.0.1:<port>`) for Desktop-app OAuth clients — the
  LAN/Tailscale address the phone reached the server on produced
  `Error 400: invalid_request`. The consent page now has to be finished in a
  browser on the server machine; Settings gained **Copy sign-in link** for
  exactly that. Proven end to end: 13 to-dos landed in the "Tangent" list.
- Settings → Google Tasks no longer forgets saved credentials on the client
  (it read a field name the server never sent).
## 1.25.0 — 2026-09-27

### Added
- **Google Tasks sync.** Settings → Google Tasks: paste a free Google Cloud
  OAuth client (Desktop app) once, tap *Connect Google*, and your to-dos
  appear in a Google Tasks list named "Tangent" — on the Google Tasks app,
  Calendar's side panel, and Assistant. Two-way: add, edit, check off, or
  delete on either side and the newer change wins. Runs on the server every
  five minutes (and on *Sync now*), so it works while your phones sleep;
  tokens never leave the server. Only title, due date, done, and deleted
  travel — never transcripts or recordings. Folders stay in Tangent.
  To-dos created in Google show a small "G" chip.
- Test-mode Google tokens expire weekly; the section shows a *Reconnect*
  banner instead of stalling silently.
## 1.24.1 — 2026-09-27

### Fixed
- **Duplicate voice to-dos across devices.** To-do changes were not on the
  auto-sync watch list, so a capture (or an edit, move, or delete) sat on
  the device until a manual or 30-minute sync. A second device transcribing
  the same recording could not see the capture and captured it again. To-dos
  now push a moment after you stop editing, like everything else.
- **Folder id collisions.** New folder ids came from the clock at microsecond
  resolution, which Windows only advances in ~1 ms steps — two folders created
  back-to-back collided. Ids are now UUIDs (same `folder-` prefix).
  Client-only; server stays on 1.24.0.

## 1.24.0 — 2026-09-27

### Added
- **Folders in To Do.** The To Do screen now groups by folder, the way
  Notebooks does: one collapsible header per folder, items inside sorted by
  due date with an Overdue / Today / date chip, 'No folder' last, and one
  collapsed Done section at the bottom. Folders are the SAME folders as
  Recordings and Notebooks — a folder holds all three.
- **Move, Edit, Delete behind ⋮** on every to-do; Move opens the folder
  picker (with 'New folder…'). **Long-press a row to multi-select**, then
  Move / Done / Delete the whole set from the toolbar (delete confirms
  once, with one Undo). Back exits selection before it leaves the screen.
  Long-press on a folder header still renames / deletes the folder;
  long-press on the date chip still clears the date.
- Server: `todos.folder_id` (nullable, absent-vs-null sentinel on sync).
  Client DB v24.

### Fixed
- A flaky transcription-service test that measured machine load instead of
  its seam (500 ms wall-clock ceiling raised).

## 1.23.1 — 2026-09-27

### Fixed
- Voice-captured to-dos no longer start with a stray period. Whisper closes
  the trigger phrase with a full stop ("…to do list. Go to the store"), so the
  first item arrived as ". Go to the store". Leading punctuation is stripped.
  Client-only; server stays on 1.23.0.

## 1.23.0 — 2026-09-27

### Added
- **To Do list.** A new checked-box icon in the top-right of the home screen
  opens your To Do list: type an item and press enter to add it (the
  keyboard stays up so you can rattle off several), tap the calendar chip
  first to give the next item a due date, check items off, tap to edit,
  and delete with a five-second Undo. Items sort into Overdue, Today,
  Upcoming, Someday, and a collapsed Done section. To-dos sync across all
  your devices like recordings and notebooks do.
- **Say it and it's on the list.** Record a brain dump and say "add to my
  to do list" (or "add to my todo list", "add that to my list", "remind me
  to", "put on my to do list") — everything after the phrase becomes
  to-do items, split on commas and "and". The recording shows an
  "Added to your To Do list" card naming what was captured, with Undo.
  Undo is permanent for that recording: re-syncing or re-transcribing
  never brings the items back.
- Server: synced `todo` entity (`todos` table; `change_log` accepts
  `entity_type = 'todo'`). No new REST endpoints — sync is the API.

## 1.22.1 — 2026-09-27

### Fixed
- Notebook page backgrounds are easier to see. The lines, graph grid, and dot
  grid were drawn in the hairline-border colour, which nearly disappeared on
  the dark page; they now use a dedicated ruling colour at twice the contrast,
  and the dots are slightly fatter. All five styles match.

## 1.22.0 — 2026-09-27

### Added
- **Page backgrounds.** Two new notebook page styles join Blank and the two
  lined rules: **Graph** (5 mm squares) and **Dot grid** (dots at the grid
  points). Pick them from the new top-right notebook menu → *Page background*
  — a sheet previews each style with the page's real painter and shows the
  current choice; the pick saves per notebook and syncs like before.

### Changed
- The page style moved out of the bottom-left insert (+) menu into the new
  top-right notebook menu, and it is now a picker: tapping no longer cycles
  blank → small → medium.
- **"Dumps" is now "Recordings"** everywhere you see it — the list title,
  search box, empty state, home tooltip, the notebook insert item, and the
  settings/export copy. The *Brain Dump* capture mode keeps its name.

### Removed
- **Meeting capture.** The home screen's mode picker and the recordings
  list's create menu no longer offer Meeting — summaries, action items, and
  speaker naming are reachable on any recording from the transcript. Existing
  meeting recordings are untouched: they keep their notes, still open
  normally, and the Mode filter still lists Meeting so you can find them.

## 1.21.0 — 2026-09-27

### Added
- **Ink to text.** Lasso handwriting in a notebook and tap *Convert to text*: the server's handwriting recognizer (the same TrOCR engine behind handwriting search) replaces the ink with a typed text block at the same spot. One undo brings the handwriting back and removes the block; one redo re-applies both. Requires the OCR environment (the install wizard offers it if missing); failures leave the page untouched.
- Server: `POST /v1/ocr/recognize` — synchronous ink recognition for the lassoed strokes, no index writes.

### Fixed
- Playback controls (and the Listen-mode waveform) now stay pinned above the transcript while you scroll — pause and play work from anywhere in a long recording instead of only at the top.

## 1.20.0 — 2026-09-27

### Added
- **Transcript → notebook.** ⋮ → *Send to notebook…* on any recording (list, multi-select, detail): pick a notebook or create one, choose a shape, done — no need to open the editor first; the snackbar's *Open* jumps to the new block.
- Text imports now read like the Markdown export: `[mm:ss] Jeff: …` per speaker turn with names from the speaker map, `h:mm:ss` once a recording passes an hour, no timestamps faked when the recording has none.
- Timestamps on the page are live: tap one to play the recording from that moment on the audio card beside it, or open the recording at that point when there is no card. Editing the text quietly drops any stamp the edit broke.
- Import shape sheet: *Include audio bubble* switch (default on, remembered).

### Fixed
- *Regenerate notes* now visibly does something: the button spins and disables while it runs and a snackbar confirms when it finishes — before, the on-device extractor finished in milliseconds with (often) identical output, so the tap looked ignored.
- Multi-select toolbar no longer overflows at 280 px.

## [1.19.0] - 2026-09-27

### Added

- Translation: recordings in another language show a language tag
  (`ES`, or `ES → EN` once translated) and 'Transcribe again' offers
  'in the original language' or 'in English'. Per recording only.
- Summary status from the server: 'Queued — 2nd in line' while waiting,
  and a red 'Summary failed: <reason>' line with Retry when the
  summarizer errors, instead of a bar that quietly times out.

## [1.18.0] - 2026-09-26

Feature release: **you can see the summary being written.**

### Added

- While your server is writing a summary, the AI summary area shows a
  progress card — an indeterminate bar, which style it is writing
  ('Writing Lecture summary on your server…') and a live elapsed
  counter. The current summary stays readable underneath until the new
  one arrives, and the Summarize button reads 'Summarizing…' and is
  disabled while the job runs (the server runs one job per recording).
- The recordings list shows a 'Summarizing…' pill on that row, and its
  ⋮ menu hides Summarize again until the job finishes.
- The state comes from the row itself (a local-only `summary_requested_at`
  stamped when the server accepts the request, cleared when the finished
  summary syncs down), so it clears the instant the answer lands — no
  polling. If no answer arrives within ten minutes (server offline, job
  failed) the card gives up rather than spinning forever.

### Changed

- Client database schema v21 (adds `dumps.summary_requested_at`, never
  synced).

## [1.17.1] - 2026-09-26

### Fixed

- Summarize: the style you pick now shows as current the moment the
  server accepts it. Previously the picker only learned the new style
  when the finished summary synced back (30-60 s), so reopening it
  straight away still ticked the old one.

## [1.17.0] - 2026-09-26

Feature release: **speaker names that stick.**

### Changed

- Speaker names are now stored per recording instead of rewriting the
  transcript text. Name someone once and it shows everywhere — the
  transcript, Listen mode headers, search results, Markdown export and
  the AI summary — and **re-transcribing keeps the names**. The
  "names will be reset" warning is gone.
- The Name-speakers sheet prefills current names, offers Clear, and
  suggests names you have used on other recordings.
- Recordings you renamed in 1.15.0 are converted automatically on first
  launch (names kept, raw labels restored under the hood) and synced.

### Server

- New `speaker_names` dump field on sync and `GET /v1/dumps/{id}`;
  invalid values are rejected with 422. Summaries see real names.

## [1.16.0] - 2026-09-26

Feature release: **take the transcript with you, with the clock on it.**

### Added

- **Export Markdown** on any transcribed recording (⋮ on the list or the
  detail screen): frontmatter (title, date, duration, speakers, summary
  template), the summary, and the transcript as one `[mm:ss] Name: text`
  line per segment — `[h:mm:ss]` once a recording passes an hour. Speaker
  names you set in 1.15.0 are used. Android/iOS open the share sheet;
  Linux/Windows write to Documents and open the file.
- Obsidian export: **Include timestamps** (off by default) and **Include
  summary** switches. With both off, exported vault files are byte-
  identical to 1.15.0 — nothing changes until you opt in.

### Fixed

- A summary that starts with its own `## Summary` heading is no longer
  doubled in exports.

## [1.15.0] - 2026-09-26

Feature release: **call Speaker 1 by name.**

### Added

- **Name speakers.** On any diarized recording, ⋮ → *Name speakers* (list
  or detail) or tap a speaker header in Listen mode. One field per
  speaker with the first thing they said as a hint; names you've used on
  other recordings appear as tap-to-fill chips. Save rewrites the
  transcript in place (`## Speaker 1` → `## Jeff`), so search, summaries
  and exports all see the name. Two speakers can't share a name.

### Changed

- *Transcribe again* warns when it will reset speaker names you added.

### Known limits

- Listen mode keeps the original `Speaker N` labels (they come from the
  server's timings, not the text). Re-transcribing resets names.

## [1.14.0] - 2026-09-26

Feature release: **teach it your words.**

### Added

- **Custom vocabulary (boost words).** Settings → *Custom vocabulary*: one
  global list of names, products and jargon (one per line or comma-
  separated) that the server feeds to faster-whisper as `hotwords` on
  every decoding window — so "Hermes" stops coming back as "Hermays".
  Live term and ~token count with a warning past the 223-token budget.
  Applies to every new transcription; use *Transcribe again* on older
  recordings. Server-owned and shared by every paired device.
- Summaries use the same list: when non-empty, a preferred-spellings
  suffix rides every summary prompt so transcript and summary agree.
- Server: `GET/PUT /v1/transcription/vocabulary` (canonicalised, case-
  insensitive first-spelling-wins dedupe, 422 on >64-char terms or >200
  terms). The list is resolved when a job *runs*, not when it is queued.

### Changed

- Transcription logs record the hotword *count* only, never the terms.

## [1.13.0] - 2026-09-26

Feature release: **find it in the transcript, and shape the summary.**

### Added

- **Transcript search depth.** Search results now show where the hit is:
  a snippet with the matched words in bold and an "N matches" chip when a
  recording matches more than once (title hits bold the title instead).
  Opening a result lands on the first match with a match bar
  ("2 of 7", previous / next wrapping at both ends); every occurrence is
  highlighted in both Edit and Listen mode.
- **Play from a match.** When the recording has word timings, the match
  bar's play button seeks 0.3 s before the matched word and plays — the
  same lead-in as tapping a word in Listen mode. Without timings the bar
  is scroll-only and the play button is absent.
- **Summary templates.** AI summaries now follow a template: Meeting (the
  prior behaviour, unchanged), Brain dump, Lecture, Actions only, and one
  Custom prompt slot. Meetings default to Meeting; brain dumps and typed
  notes default to Brain dump. The server owns the presets
  (`GET /v1/summaries/templates`) so the client never hardcodes the list.
- **Summarize again.** Recording detail gains a Summarize / Summarize
  again button (and the list's ⋮ Regenerate summary now goes the same
  way) that opens a template picker with the current template marked. The
  old summary stays on screen until the new one arrives via sync.
- **Custom template editor** in Settings → AI summaries: a multiline
  prompt with an explicit Save and a Clear. The server appends the
  headings / "None" / same-language contract to every custom prompt so a
  careless prompt cannot break the output shape.

### Changed

- `POST /v1/dumps/{id}/summarize` accepts an optional `template` id
  (422 for an unknown id or an unconfigured Custom slot); dumps carry a
  server-owned `summary_template` field through sync (client DB v19,
  absent-vs-null sentinel like the summary columns).
- `GET/POST /v1/summaries/settings` carry `custom_prompt` and
  `custom_configured`.

## [1.12.0] - 2026-09-26

Feature release: **tap a word, hear that moment.**

### Added

- **Listen mode.** Transcripts get an Edit | Listen toggle. Listen shows
  the transcript as tappable words: tap one and playback jumps to just
  before that word (0.3 s lead-in) and plays. The current word highlights
  and auto-scrolls as audio plays — karaoke style. Low-confidence words
  are tinted so a suspect transcription is visible at a glance.
- **Waveform scrubber** above the Listen view: the recording's real
  amplitude envelope (600 buckets, computed server-side during
  transcription — Opus never has to be decoded on-device), draggable to
  seek.
- Word-level timestamps from faster-whisper (`word_timestamps=True`),
  synced to every device as a new server-owned `transcript_timings`
  field alongside the transcript (client DB schema v18). Recordings
  transcribed before 1.12.0 carry segment-level timing (tap a sentence)
  until re-transcribed; a **Re-transcribe for word timing** button is
  offered on those.
- Settings → **Export database copy**: writes a consistent snapshot of
  the local metadata database (no audio) to a folder reachable by
  `adb pull` on release builds. Diagnostic tooling; it found the sync
  bug below.

### Fixed

- **Server-authored sync changes were silently discarded** on the device
  that made the recording: its own completion timestamp was newer than
  the server's row time, so the newer-wins rule dropped the incoming
  timings (and would have dropped any future server-computed field).
  Server-authored changes now always land; device edits still compete on
  updated_at.
- Ethernet counted as a metered connection, so the default Wi-Fi-only
  preference refused every audio download on a wired desktop. Ethernet
  now ranks with Wi-Fi.
- just_audio keeps its playing flag raised after a clip completes, and
  play() is a no-op while it is set — so after one full listen, a word
  tap (seek + play) went dead. Seeking a completed player now pauses
  first.
- Audio-download failures surfaced only in a status line far below the
  fold; they now also raise a SnackBar at the tap site, and the playback
  panel says "Audio is on the server. Download it to play." instead of
  "Recording storage is unresolved".
## [1.11.0] - 2026-09-25

Feature release: Tangent runs natively on Windows, at full parity with
the Linux desktop app.

### Added

- **Windows desktop app.** `tangent-setup-x64.exe` (per-user Inno Setup
  installer, no admin prompt; optional desktop icon and start-at-sign-in)
  attached to every release alongside the AppImage and APK. Everything
  the Linux app does: system tray (left-click opens, right-click menus),
  close-to-tray, single instance (a second launch focuses the running
  window), and a **global Ctrl+Alt+R record hotkey** that works with the
  window hidden. Playback via media_kit/libmpv.
- Release CI builds and *verifies* the Windows installer on a
  `windows-latest` runner (silent-install, then require the exe to land)
  before attaching it, mirroring the AppImage payload check.

### Changed

- Windows records **WAV (PCM)** rather than Opus: Media Foundation ships
  an Opus decoder but no encoder, so the app uses the raw-PCM capture
  path the mic-gain feature already proved end-to-end. Transcription
  accuracy is unaffected — the server decodes both through ffmpeg. Linux
  and Android keep Opus. The Settings mic-gain note now says which format
  applies on the current platform.
- The Windows single-instance rendezvous is a loopback-TCP socket with
  an OS-assigned port recorded in `%LOCALAPPDATA%\Tangent\instance.port`
  (Dart has no Unix sockets on Windows); the Linux Unix-socket path and
  the `show`/`toggle-record` command protocol are unchanged.

### Fixed

- **Find my server** on desktop. The sweep took the first non-loopback
  IPv4 it found, so a Tailscale (CGNAT) or WSL/Hyper-V adapter could win
  and the /24 probe scanned the wrong network. Candidates are now ranked
  (physical 192.168/10.x first, virtual adapters and 172.16/12 last,
  CGNAT never swept), and the device's **own** address is probed too —
  a desktop hosting the server in Docker answers on its LAN address.
- Real Tangent icon on Windows (window, taskbar, tray) instead of the
  Flutter template icon.
- The Linux AppImage now bundles the tray_manager (appindicator) and
  hotkey_manager (keybinder) runtime libraries with the rest of the
  non-baseline closure.
- Client test suite is host-agnostic: fully green on a Windows bench
  (1819 passed, 2 skipped) as well as Linux CI.

## [1.10.0] - 2026-09-25

Feature release: pick your Whisper model, and always know which one is running.

### Added

- **Whisper model picker** in Settings → Server transcription. All five
  sizes (`large-v3`, `medium`, `small`, `base`, `tiny`) listed in accuracy
  order with Installed badges; `large-v3` is the default and recommended.
  Selecting an uninstalled model prompts with the download size, shows
  progress inline and in the notification shade (id 1004), and
  auto-selects when the download completes. Reopening Settings during an
  install re-attaches to the running progress instead of starting a second
  download. Installed non-active models can be deleted; the active model
  cannot.
- Server: `GET /v1/transcription/models`, `PUT /v1/transcription/model`,
  `POST /v1/transcription/models/install` + `/progress`, and
  `DELETE /v1/transcription/models/{name}`. The persisted selection
  overrides the `WHISPER_MODEL` env default, and the engine resolves it at
  load time, so switching models needs no container restart.
- The transcription notification and the recording screen's progress line
  name the active model (`1 recording · large-v3`) instead of the engine.

### Fixed

- Save and Transcribe again no longer sit behind the Android navigation
  bar on devices with a tall taskbar (the Fold); the recording screen
  reserves the system inset, and keeps it while the keyboard is up.
- `/v1/server/info` reports the model actually in use rather than the env
  default.
- Model installs are atomic: a failed or interrupted download leaves no
  half-published model directory, and a model is only reported Installed
  when its weights are a real file (guards against the hub cache's
  dangling-symlink layout).

## [1.9.0] - 2026-09-25

Feature release: your server reads the meeting so you don't have to.

### Added
- **AI meeting summaries.** After a meeting is transcribed, the server
  writes a short summary — what was discussed, decisions, action items,
  open questions — below the transcript, and it syncs to every device.
  Entirely local: a 4B-parameter instruct model (Qwen 3 4B Instruct 2507,
  Q4_K_M) runs on your own server via llama.cpp; nothing leaves your
  network. Off by default behind a Settings toggle with a one-time install
  wizard (about 2.5 GB, progress in-line and in the notification shade;
  survives app restarts). Sections with nothing to report are omitted
  rather than invented. Uninstalling keeps every summary already written.
  GPU is used when the runtime supports it; otherwise CPU — accuracy is
  identical either way, only speed differs.
- **Regenerate summary** from a meeting's ⋮ menu.
- **Summaries in notebooks.** "Import meetings" now offers *Summary* and
  *Transcript + summary* alongside the audio bubble and transcript, and
  audio bubbles show the summary's first line under the title — a summary
  that arrives later appears without re-importing.
- Summaries render as formatted text (headings, bullets) on the recording
  screen.

### Fixed
- The AI-summaries toggle reflects the server's setting when Settings
  opens, so a change made from another device is not shown stale.
- The summarizer's CUDA runtime is vendored into its own environment and
  found even though the venv's Python is a symlink; when the GPU selftest
  fails the install falls back to CPU instead of failing.

### Known
- On Blackwell GPUs (RTX 50-series) the prebuilt CUDA llama.cpp wheel does
  not yet include sm_120 kernels; summaries run on CPU there (~40 s each)
  until upstream ships CUDA 12.8+ wheels.

## [1.8.0] - 2026-09-23

Feature release: capture and export round out the daily loop.

### Added
- **Automatic Bluetooth microphone routing.** Recording now behaves like a
  phone call: when a Bluetooth headset is connected its mic is used,
  otherwise the built-in mic — no manual picking. First record prompts for
  the Nearby-devices permission it needs, and a new "Auto-enable Bluetooth
  audio" toggle in Settings (default on) explains the narrowband quality
  tradeoff.
- **Bulk audio import.** Settings → Import → "Import audio files..." accepts
  a multi-selection and imports sequentially with per-file progress; one
  bad file is named in the summary and never aborts the rest.
- **One-shot Obsidian export.** Settings can export the library as a folder
  of Markdown notes suitable for dropping into an Obsidian vault.
- **Notebook home-screen widget (Android).** A 2×2 launcher widget that
  opens straight into a chosen notebook.
- **Published REST API docs.** The server's interactive `/docs` endpoint is
  now enforced and documented in the README.

### Changed
- The app's display name is capitalized ("Tangent") on the Android
  launcher and in the Windows window title and file metadata. Package ids
  and executable names are unchanged — installed apps keep their data.
- The notebooks list streams headers instead of decoding full ink
  documents, keeping the home screen fast as the library grows.

### Fixed
- GPU transcription is restored on CUDA-capable servers: the container now
  ships the CUDA 12 runtime libraries the inference engine actually links
  (verified by real in-container inference on an RTX 5070 — a 71-second
  recording transcribes in ~4.5 s vs ~40 s on CPU). CPU-only hosts are
  unaffected; the device probe from v1.7.2 keeps them on CPU.

## [1.7.2] - 2026-09-23

Patch release: three user-visible fixes found on real devices, plus a
meeting-notes format overhaul.

### Fixed
- **Fountain-pen strokes appeared to erase the ink underneath them.** The
  batched italic-nib renderer emitted segment quads whose winding direction
  flipped at every cursive loop or reversal; under the nonzero fill rule two
  overlapping opposite-winding quads cancelled to a transparent hole exactly
  where letters self-cross. No ink was ever lost — the strokes were intact
  on disk and reappear whole after updating. Quads are now normalized to a
  single winding direction so overlaps can never cancel. PDF export used the
  same painter and is fixed by the same change.
- **Meeting recordings lost their speaker labels.** Speaker diarization
  crashed with a short-final-chunk error on any recording whose length was
  not a clean multiple of its processing window (i.e. most recordings), and
  the transcript silently degraded to unattributed paragraphs. The audio is
  now decoded once and handed to the diarizer as a waveform — the same
  16 kHz mono stream the transcriber hears, which is also the diarization
  models' native rate — so the chunked-decode failure cannot occur.
- **Transcription failed on GPU-enabled servers.** With the GPU compose
  override active, the Whisper backend auto-selected CUDA, but the container
  ships CUDA 13 wheels while the inference runtime links the CUDA 12
  libraries — every transcription failed at first inference (model load
  succeeds; the libraries load lazily). The server now probes for the exact
  runtime libraries before choosing a device and falls back to CPU when they
  are absent. `TANGENT_WHISPER_DEVICE=cpu|cuda` overrides the probe.
- **Release builds could crash at startup after the notification plugin's
  code was shrunk.** R8 stripped generic-type metadata the notifications
  plugin needs; the resulting exception during early init killed sync and
  presented as "can't connect to the server." Keep rules now preserve the
  metadata, and a notification-plugin failure can no longer break startup or
  sync — it degrades to no-notifications with a logged warning.

### Changed
- **Meeting transcripts are now grouped by speaker, not by time.** Instead
  of timestamped paragraphs interleaved in chronological order, the
  transcript renders one section per speaker (numbered by order of first
  appearance) containing everything that speaker said. Text the diarizer
  could not attribute lands in a final `[unattributed]` section. Recordings
  where diarization found no speakers keep the timestamped layout. Server
  and on-device transcription produce byte-identical output. Existing
  meeting notes keep their old text until re-transcribed.
- Settings gained a Licenses page (Tangent's AGPL-3.0 text plus every
  bundled package license), and the Settings footer now reads its version
  from the build instead of a hard-coded string.

## [1.7.1] - 2026-09-22

Patch release: two fixes found running v1.7.0 on real devices.

### Fixed
- **Handwriting search showed "No matches" forever on devices that upgraded
  from an older version.** A device that had been syncing before v1.7.0 had
  its sync checkpoint already past the search index entries, so the index
  never arrived — search looked enabled but always came up empty (a fresh
  install was fine, which is why it slipped through). The server can now
  re-announce the index (`POST /v1/ocr/index/backfill`), and the app asks
  it to automatically when you enable handwriting search on an
  already-provisioned server. Existing devices heal themselves the next
  time the toggle is turned on.
- **Unpaired desktop pointed at an Android-emulator-only address.** A
  Linux/Windows desktop that had never paired defaulted every request to
  `10.0.2.2` — an address that only means something inside the Android
  emulator — and silently timed out. The desktop default is now
  `http://localhost:8765` (the documented server port): correct when the
  server runs on the same machine, and an instant, visible
  "connection refused" instead of a silent hang everywhere else.

## [1.7.0] - 2026-09-22

Handwriting search: find your handwritten notes by typing what you wrote.

### Added
- **Handwriting search** — type a word and Tangent finds it in your
  handwritten notebooks. The search icon sits in the toolbar on both the
  Notebooks list and inside a notebook: the list shows which notebooks match
  with a count and a snippet, and opening one jumps straight to the match
  with the word highlighted on your actual ink. Next/prev walks the matches
  and wraps at the end, Ctrl+F style.

  Recognition runs **on the server**, so search works on every device that
  syncs — including Linux desktop, which has no on-device handwriting
  recognizer at all. Your notebooks sync up, the server reads them, and the
  resulting index syncs back down: **searching itself is local and offline**
  on every device.

- **Handwriting search install wizard** (Settings → Handwriting search) —
  off by default. Turning it on downloads the recognition model with a
  progress notification and a completion notification. Both a CPU and an
  RTX (GPU) flavour are supported: **the GPU flavour is not more accurate**,
  it is the same model running faster. Turning the feature off removes the
  model and the index entirely.

- **Optional GPU compose override** — `server/docker-compose.gpu.yml`, layered
  on with `-f docker-compose.yml -f docker-compose.gpu.yml`. The stock compose
  file stays CPU-only so a GPU-less homelab still works unchanged.

### Fixed
- **Handwriting no longer gets cut off on narrow screens** — a notebook page
  was scaled to fit the typed-text column rather than its actual content, so
  on a narrow screen (a foldable's cover display, for example) everything
  written past that column was clipped off the right edge with no way to
  scroll to it. Pages now scale against their real content width: ink,
  imported images, and blocks you have dragged to the right. Pages that fit
  the column render exactly as before.

- **Notifications can no longer take the app down at startup** — in a release
  build the notification plugin could fail to initialise and kill the startup
  sequence with it, leaving the app running but never syncing, which looked
  for all the world like the server was unreachable. Notification failures now
  degrade to "no notifications" and are logged; sync always starts.

- **Server info no longer times out once handwriting search is installed** —
  the storage-usage figure walked the whole data directory including the
  ~9 GB recognition environment, taking over a minute and exceeding the app's
  request timeout. Every device then reported the server as unreachable and
  stopped syncing. The recognition environment is now skipped (it is
  reinstallable machinery, not your data) and the call returns in a fraction
  of a second.

- **Changing servers no longer leaves handwriting search on the old one** —
  the Settings section cached the server address at first load, so after
  pointing the app at a different server the handwriting toggle silently kept
  talking to the previous one until the app was restarted.

- **Returning to Settings mid-install shows live progress** — leaving the
  Settings screen while the model downloaded and coming back showed an error
  instead of the running install.

### Known behaviour
- If an install finishes while you are away from the Settings screen, the
  toggle rests OFF until one tap flips it on. This is deliberate: a device
  that installs the model must not silently enable the feature on your other
  devices.

## [1.6.1] - 2026-09-21

Quality-of-life release: the notebook tools now behave the way they look.

### Added
- **Pairing codes in Settings** — "Pair a new device" on any paired device
  shows pending 6-digit codes big enough to read across the room, with the
  requesting device's name, platform and a live 120-second countdown,
  refreshed every 5 seconds. No more reading codes out of the docker log.
- **Pen hover cursor** — a thin ring follows the S-Pen while it hovers,
  showing exactly where the nib will land and how wide the mark will be:
  pen stroke width, the highlighter's full rendered band, or the eraser's
  reach when erasing (side button included). Stylus only — a mouse never
  shows it — and the lasso pen stays ring-free.

### Fixed
- **Eraser reaches the whole highlighter band** — erase reach followed the
  nominal stroke width, so most of a wide highlighter band was untouchable;
  it now follows the rendered ink per tool. Pen erase reach is unchanged.
- **PDF export renders imported images** — exported pages drew a
  "🖼 Picture" placeholder where images sat; the actual image pixels now
  render at the block's position, with the placeholder kept only as the
  fallback for undecodable image data.
- **Lasso catches wide rows where you see them** — text and checkbox rows
  were lassoed against a nominal 300×90 box regardless of rendered width,
  so circling the right half of a full-width row selected nothing. The
  lasso now measures the real laid-out size (images already used theirs;
  the 40% catch threshold is unchanged).
- **Server setup hint names the server, not the user** — the first-run
  example suggested `"display_name": "Your Name"`, so servers introduced
  themselves by their owner's name; the example is now "Tangent Server"
  with a note that the name is the machine's.

## [1.6.0] - 2026-09-21

Linux desktop companion (verified on CachyOS, KDE Plasma 6 Wayland) and
notebook pen upgrades. The client now runs natively on Linux with the
full notebook/dump feature set, packaged as `Tangent-x86_64.AppImage` —
now built and verified in CI rather than by hand.

### Added
- **Pen colours** — long-press the pen for its palette (white, blue,
  red, amber). The pen keeps its colour for the session and the toolbar
  icon tints itself to match.
- **Highlighter** — a real highlighter beside the pen: a wide,
  translucent chisel band that always paints *beneath* handwriting, so
  ink stays crisp on top. Its own long-press palette (yellow, lime,
  blue, pink) and its own colour memory. Highlights export pixel-true
  to PDF, and notebooks keep their exact on-disk format — files with no
  colours re-encode byte-identical.
- **Insert images into notebooks** — the notebook ⋮ menu places a photo
  or image file on the page as a movable block; lasso, drag and undo
  treat it like any other block. (Linux desktop port included.)
- **Linux desktop support** — the Flutter client builds and runs
  natively on Linux. Storage uses real directories
  (`~/Documents/Tangent/`, no folder-authorization step); playback of
  recorded and synced audio is bridged to libmpv via media_kit
  (just_audio has no Linux backend); recording captures through
  PipeWire (`parecord` + `ffmpeg`) with the same 16 kHz mono Opus
  pipeline as Android.
- **System tray icon** — Tangent lives in the tray (StatusNotifierItem
  spoken directly over D-Bus). Left-click opens the app window;
  right-click offers Open App / Start Recording / Exit. Implemented
  without libappindicator, which hardcodes menu-on-left-click.
- **Close-to-tray** — the window's X button hides to the tray instead
  of quitting (the global hotkey needs a living instance); the tray's
  Exit is the one real quit. Only armed when a tray host exists, so a
  trayless desktop keeps normal close-to-quit.
- **Global record hotkey** — `tangent --record` from a second process
  forwards a toggle to the running instance over a Unix socket in
  `XDG_RUNTIME_DIR` and exits; bind it to a key (e.g. Meta+R via KDE
  custom shortcuts) to start/stop a capture from anywhere on the
  desktop. A plain second launch raises the existing window instead.
- **Right-click = long-press** — every long-press context gesture
  (multi-select on dump/notebook rows and covers, folder header
  rename/delete) also fires on mouse right-click, derived from the same
  handler so the two inputs cannot drift.
- **AppImage packaging** — `packaging/build-appimage.sh` wraps the
  Flutter bundle plus libmpv and its non-baseline dependency closure
  into a self-contained `Tangent-x86_64.AppImage`.

### Fixed
- **Notebook toolbar tools tappable any time** — the draw-mode tools no
  longer require entering draw mode first; tapping eraser, nib or lasso
  from cold activates draw mode with that tool, matching the pen.
- **Wide highlighter marks near the page edge no longer clip in PDF
  export** — content bounds now pad for the highlighter's full band
  width instead of a fixed margin.
- **First words clipped on Linux** — record_linux reports "started"
  when `parecord` spawns, ~120–190 ms before the PipeWire stream is
  live. The recorder now holds "recording" until the mic stream shows
  real amplitude (bounded at 700 ms so a hardware-muted mic can't hang
  the button).
- **PDF export crashed on Linux** — the share sheet path ends in
  share_plus's `shareXFiles`, which is unimplemented on Linux. Desktop
  exports now land in `Documents/Tangent/Exports/` (collision-safe
  names, never overwrites) and open in the system viewer, with the
  path shown either way.
- **Missing Secret Service no longer breaks startup** — without
  KWallet/gnome-keyring, secure-storage reads throw; startup now
  launches unpaired and the connect screen states the problem instead
  of crashing or showing silently empty fields.
- **Linux build with clang ≥ 18** — vendored plugin code
  (flutter_secure_storage's json.hpp, appindicator headers) tripped
  `-Werror` on newer diagnostics; those exact warnings are downgraded,
  guarded by compiler capability checks.

## [1.5.1] - 2026-09-20

### Changed
- **One unified notebook toolbar** — draw toggle, eraser, nib, lasso,
  undo, redo and the pen-size slider share a single always-visible row
  under the title; the second drop-down row is gone. Outside draw mode
  the tools are disabled (grayed), never hidden, so the row never
  reshuffles and a stray tap can't erase or lasso.

### Fixed
- **Eraser performance on full pages** — erasing (and repainting while
  writing) slowed down as a page filled. Stroke hit-testing now rejects
  distant ink with a cached bounding-box check, and a fountain stroke
  renders as one native draw call instead of one per segment. Same
  pixels, verified at the paint level.

## [1.5.0] - 2026-09-20

### Added
- **Folders for dumps** — the Dumps list groups into the same folders as
  notebooks: collapsible headers with counts, unfiled items under
  "No folder". It is one folder system: file a dump into "Work" and it is
  the same "Work" your notebooks use; deleting a folder from either screen
  safely unfiles contents from both. Search results stay flat.
- **Folder rename and delete** — long-press a folder header (in either
  list) for rename/delete. Deleting a folder never deletes its contents;
  they move to "No folder" and the change syncs to other devices.
- **Export to PDF** — the ⋮ menu on any notebook renders it to a PDF
  (ink drawn by the editor's own painter, so pen styles export
  pixel-true; text and checkbox blocks at their positions; page sized to
  the content) and hands it to the system share sheet.
- **Import as audio bubble or text** — confirming the dump picker in a
  notebook now asks how the batch should land: as the draggable playable
  card, or as the transcript in an ordinary editable text block (with an
  honest "(no transcript)" placeholder when there is none).

### Changed
- **Unified list gestures** — long-press on a notebook (row or cover)
  enters the same multi-select mode dumps have (select-all, bulk delete);
  the ⋮ button carries the per-item menu (open, rename, move to folder,
  export, delete).
- **Content-aware insert** — items imported into a notebook land below
  the lowest existing content (blocks and ink), stacking downward,
  instead of cascading from the page top over what is already there.

## [1.4.0] - 2026-09-20

### Added
- **Server discovery** — "Find my server" on the connect screen sweeps the
  local /24 for Tangent servers (unauthenticated `/v1/server/info/public`
  beacon: name, version, auth flag — nothing private) and lists finds live.
- **Pairing** — a device earns its own bearer token by typing a 6-digit code
  read off the server's log (`pairing.code_issued`). Codes live 120 seconds,
  are stored hashed, and die after 5 wrong attempts; each device's token is
  individually revocable via `DELETE /v1/devices/{id}/token`. Manual
  URL + token entry remains for VPN/Tailscale setups the sweep can't see.
- **Multi-step undo/redo** in notebooks — history stacks 100 actions deep
  (strokes, erase sweeps, lasso moves, lasso deletes); redo walks forward
  step by step and any new mutation clears it.
- **Smart lasso** — circle-select ink, text blocks and recording cards
  together (anything >40% inside the loop is caught); drag the selection
  anywhere or delete it as one, with undo. Works with pen and finger.
- **Fountain pen and italic nib** pen styles — pressure-tapered rendering
  with per-style stroke character; raw pressure is stored per point and
  curves apply at render time, so old notebooks gain the styles too.
- **Save-on-back everywhere** — backing out of a notebook or a text note
  saves it; the discard-confirmation dialogs are gone. A failed save keeps
  the screen open with the error visible instead of silently losing work.

### Changed
- Notebook toolbar restructured: the top row is stable (draw toggle, undo,
  redo, save); eraser, nib, lasso and delete live in a second row shown only
  in draw mode.
- Palm rejection no longer suppresses finger input while the lasso is
  active (a selection gesture can't scribble).
- `require_auth` accepts device-bound tokens minted by pairing alongside
  the primary setup token.

### Fixed
- A cancelled gesture (system edge-swipe, palm, second finger) could
  permanently wedge the lasso; pointer-cancel now releases every mode's
  claim and rolls back half-finished selection drags.
- The DEBUG banner no longer shows on debug builds.
- Wrong pairing-code attempts are counted even though the request returns
  401 (the counter previously rolled back with the error response).

## [1.3.0] - 2026-09-19

### Added
- **Notebooks** — endless vertical scrolling page mixing handwriting, typed
  text, checkboxes and embedded recordings. Blocks and imported cards are
  draggable; tapping a recording card opens it for playback.
- **Notebook folders** — file notebooks into folders; folder sections render
  in both the named list and the cover-grid view.
- **Collapsible folder sections** — tap a folder's name in the Notebooks list
  to fold the section down to its header (rotating chevron affordance); tap
  again to expand. State is shared across the list and cover views.
- **Cover-grid view for notebooks** — Samsung-Notes-style book covers as an
  alternate view, persisted across restarts.
- **Audio download (single + bulk)** — pull a synced recording's audio from
  the server back onto the device. Per-row "Download audio" menu entry and a
  bulk "download all audio" toolbar action; downloads land in
  `Tangent Synced Audio/` with playable bindings (publish → attach → bind).
- **Bulk transcribe** from the selection toolbar.
- **Action-agnostic multi-select** in the Dumps list.
- **Stroke eraser** on the pen toolbar, erasing for the whole gesture.
- **Import audio** — bring an existing audio file into Tangent from the home
  screen. The file is copied (never moved) through the same reserve → stage →
  publish path a live recording uses.
- **Text notes** — typed entries alongside voice dumps, with their own durable
  `Tangent Text Notes/` directory.
- **Bluetooth/external microphone selection** for capture.
- Optional **speaker diarization** on the server (pyannote, off by default).
- Segment timestamps in server job results.

### Changed
- **Transcription now runs on your own server, not on-device.** The Android
  whisper.cpp path was replaced by the self-hosted FastAPI + faster-whisper
  server. Recording, playback, notebooks and search remain fully offline.
- Recordings stay on the device by default; syncing to a server is an explicit
  choice, no longer conflated with transcription.
- **Dumps filters collapsed into one dropdown bar** — two stacked chip rows
  became a single row of two dropdowns (`Mode · All ▾` / `Transcript · All ▾`);
  the closed anchor always names the active selection.

### Fixed
- **Stop latency ~10.4 s → ~1.8 s** (T8). The receipt proof was enumerating and
  parsing the entire recordings folder after every capture; it now reads the one
  entry it just wrote.
- **Download with no usable storage folder now says so** ("Choose a storage
  folder first") instead of silently doing nothing — an enabled control that
  did nothing was indistinguishable from a broken app.
- Downloaded synced audio actually plays: the path resolver (Kotlin and Dart)
  both learned the `Tangent Synced Audio/` folder.
- "Select all" selected only a couple of rows; selection is now
  action-agnostic.
- Notebook cards could not be dragged slowly — the page scroll won the gesture
  arena before the card's threshold was reached. The page now yields on touch.
- Card taps, per-block delete, and backspace-deletes-empty-line in notebooks.
- Durable notebook files are re-adopted at startup and republished on save.
- Several SAF publication defects around MIME-coherent names and text notes.
- Transcription status repaired on recordings that synced before the fix.

### Known issues
- Recordings fenced by earlier interrupted runs fail bulk download with
  `Recording identity is fenced`; the fence is never released. Under
  investigation.
- A failed audio fetch (e.g. server unreachable) is not yet surfaced in the
  UI; the download simply does not happen.

## [1.0.0] - 2026-09-13

### Added — Server
- FastAPI server with SQLite (WAL mode) + faster-whisper transcription
- Token-based auth (SHA-256 hashed, single-user per install)
- First-run setup flow that prints a setup URL and returns an API token
- Dump CRUD endpoints (`POST/GET/PATCH/DELETE /v1/dumps`)
- Audio upload endpoint (`POST /v1/dumps/{id}/audio` — multipart, idempotent overwrite)
- Audio download endpoint (`GET /v1/dumps/{id}/audio`)
- Transcription job queue with explicit commits to fix BackgroundTasks race
- Server-Sent Events (`GET /v1/jobs/{id}/stream`) for real-time job progress
- Secretary mode post-processing: extracts action items from meeting transcripts
- Model management (`GET /v1/models`, `POST /v1/models/{name}/pull`)
- Server info endpoint with storage stats (`GET /v1/server/info`)
- structlog logging throughout
- Health check endpoint via `GET /v1/server/info`
- Dockerfile + docker-compose.yml for production deploy

### Added — Client (Flutter)
- On-device Android Whisper large-v3 transcription with checksum-pinned model storage
- In-app recording player with play/pause, elapsed/total time, and draggable seek bar
- Persistent local-transcription progress panel with stages, elapsed time, determinate progress, and cancellation
- Live Dumps-list indicator identifying the clip and stage currently being transcribed
- Loaded-model reuse for sequential notes with idle native-memory cleanup
- Voice recording (opus, 16kHz mono, ~32 kbps) via `record` package
- Big red record button on home screen with live timer
- **Brain Dump mode** (default) — verbatim transcription
- **Meeting mode** — secretary-formatted summary
- Deterministic offline Meeting notes derived only from the local transcript, with separate raw-transcript storage and no meeting upload
- Local SQLite with FTS5 full-text search across dumps
- Local-first storage (always saves before syncing)
- Sync engine: batches pending dumps to server, retry + failure tracking
- Dumps list screen with reactive updates and search
- Persistent All / Brain Dump / Meeting / Awaiting list filters that compose with search
- Dump detail screen: edit title, view transcript, delete, re-transcribe
- Server connection screen: URL + token entry with "Test & Connect"
- Settings screen: trigger mode (tap vs hold), Wi-Fi-only sync, server reconfig
- API token stored in Android Keystore via `flutter_secure_storage`
- SSE client with polling fallback when SSE unavailable
- Connectivity-aware sync (skips when offline or Wi-Fi-only on cellular)
- Path: Android (verified build), Linux, Windows (deps installed)

### Tests
- 57 server tests (pytest) — unit + integration
- 56 client tests (flutter test) — unit + widget
- 1 live SSE integration test (skipped without `TANGENT_LIVE_URL`)
- 114 total tests, all passing

### Documentation
- README rewritten — actual install + run instructions
- AGENTS.md + CONTRIBUTING.md for contributors

### Fixed
- BackgroundTasks race where enqueued jobs were silently dropped (added explicit `db.commit()` in `enqueue_job`)
- SQLite threading issue with async endpoints (added `check_same_thread=False`)
- Broken Dockerfile CMD (changed from `python -m app` to uvicorn factory)

## [0.1.0] - 2026-09-08

### Added
- Initial brainstorming + design spec
- Phase 1 server (FastAPI + SQLite + faster-whisper) — 46 tests
- AGPL-3.0 license
- Docker Compose config

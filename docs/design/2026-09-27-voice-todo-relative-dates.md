# Voice to-do dates, round 2: relative dates + per-item dates (2026-09-27)

v1.26.0 recognises one absolute date phrase at the front of the to-do
sentence. Real speech says "Friday" and "tomorrow", and puts dates on
individual items. This arc lifts D1 and D3 of
`2026-09-27-voice-todo-due-dates.md`.

Ships as **v1.27.0**, client-only.

## Jeff's picks (recorded)

- **R1 A weekday name on that same weekday means NEXT week's.** "on Friday"
  said on a Friday = 7 days out. "Today" is the word for today.
- **R2 Per-item beats the sentence date.** "for Friday: buy milk, and call
  mom on Sunday" → milk due Fri, mom due Sun. Items without their own
  date inherit the sentence date; with no sentence date they stay undated.
- **R3 "next week" = Monday of next week; "next month" = the 1st of next
  month.** A concrete day, ordinary date chip.
- Carried over unchanged: D2 (resolve against the RECORDING's `created_at`,
  local calendar; absolute month+day rolls forward, never a past date),
  impossible absolute dates stay text.

## Phrases (all case-insensitive; `<DATE>` from v1.26.0 is one alternative)

| Phrase | Resolves to (relative to `recordedOn`, date part) |
|---|---|
| `today` | recordedOn |
| `tomorrow` | +1 |
| `the day after tomorrow` | +2 |
| `<weekday>` / `this <weekday>` / `on <weekday>` | next occurrence STRICTLY after recordedOn (R1: same weekday → +7) |
| `next <weekday>` | same as `<weekday>` — no "week after next" arithmetic; speech is ambiguous and the chip is editable |
| `in N days` / `in a day` / `in N weeks` / `in a week` (N as digits OR words one–thirty) | +N / +7N |
| `next week` | Monday strictly after recordedOn (R3) |
| `next month` | 1st of the following month (R3) |
| `end of the week` | the coming Sunday (or recordedOn if it is Sunday) |
| `end of the month` | last day of recordedOn's month |
| `<DATE>` (v1.26.0 absolute forms) | unchanged |

Weekday spellings: full names + `mon tue tues wed weds thu thur thurs fri
sat sun`, optional trailing `.`. Prepositions before any phrase: `for | on |
by | due (on)? | this (only before a weekday)`; optional `the` where it
reads naturally (`the day after tomorrow`, `the end of the week`).

NOT parsed (stay text): times of day ("at 3"), "this weekend", "soon",
"later", "someday", "in a few days", "a week from Friday", ranges.

## Where phrases are recognised (R2)

1. **Sentence date** — exactly as v1.26.0: at the head of the span, right
   after the trigger, before splitting. Any phrase from the table.
2. **Per-item date** — after splitting, on each item: ONE date phrase at
   the item's END (`… on Sunday`, `… by the 30th of September`, `…
   tomorrow`) OR at its START (`Sunday call mom`, `tomorrow buy milk`).
   End wins if both match (the end form is what people say). The phrase
   and its preposition are removed; the remaining text is cleaned as
   today. If removal would leave an item empty, the phrase was the whole
   item — keep the original text, no date.
3. **Precedence per item:** own date → sentence date → null.

A phrase in the MIDDLE of an item ("call mom on Sunday about the trip") is
NOT recognised — the item stays whole and undated (or inherits the
sentence date). This is deliberate: a middle-of-sentence weekday is as
often a topic as a deadline.

Ambiguity guards (each has a fixture):
- `may` is a month only when followed by a day number ("may 30"); "may
  call mom" is text.
- `sun`/`sat`/`mon` etc. only when followed by end-of-item, `.`, or `,` —
  "buy sun screen", "mon ami" are text. Full weekday names likewise need
  a word boundary.
- `in 3 days` only with a number word or digits — "in days like these" is
  text.
- "today" inside a longer word ("todays paper" has no apostrophe from
  Whisper) — require a word boundary on both sides; "todays" is text.

## Public shape

```dart
class VoiceTodoItem { final String text; final String? dueDate; }
class VoiceTodoParse {
  final List<VoiceTodoItem> entries;   // NEW: per-item
  List<String> get items;              // texts only — existing callers/tests unchanged
  String? get dueDate;                 // the SENTENCE date, as before
}
```

`captureVoiceTodos` writes `entry.dueDate ?? parse.dueDate` per row. Every
existing v1.26.0 test passes unchanged through the getters.

## Real-data-shaped fixtures (verbatim in tests; recordedOn 2026-09-27, a Sunday)

1. `Add to my to-do list, call the dentist on Friday.` → `[call the dentist]` due `2026-10-02`
2. `Add to my to-do list for Friday, buy milk and call mom on Sunday.` → milk `2026-10-02`, mom `2026-10-04` (R2)
3. `Remind me to take the bins out tomorrow.` → due `2026-09-28`
4. `Add to my to-do list, pay rent next month and renew the plates next week.` → rent `2026-10-01`, plates `2026-09-28` (R3; Sep 27 is a Sunday so "next week" is the very next day)
5. `Add to my to-do list for Sunday, wash the car.` recorded Sunday 2026-09-27 → due `2026-10-04` (R1)
6. `Add to my to-do list, buy sun screen and call mon ami.` → both text, no dates (guards)
7. `Add to my to-do list, in three days call the vet.` → due `2026-09-30`
8. `Add to my to-do list, call mom on Sunday about the trip.` → `[call mom on Sunday about the trip]`, no date (middle-of-item rule)
9. `Add to my to-do list, today.` → `[today]`, no date (phrase-was-the-whole-item rule)
10. v1.26.0 fixture 1 (`…for September 30th to go to the store.`) → unchanged.

## Sabotages (each must fail a named test, real output quoted)

- S1 weekday resolves to `>=` instead of `>` → fixture 5 yields `2026-09-27`.
- S2 sentence date overrides the item's own → fixture 2 mom yields `2026-10-02`.
- S3 drop the word-boundary guard on short weekday forms → fixture 6 strips "sun".
- S4 "next week" = +7 instead of next Monday → fixture 4 plates yields `2026-10-04`.
- S5 per-item phrase matched anywhere, not just start/end → fixture 8 gets a date.
- S6 `captureVoiceTodos` writes only `parse.dueDate` → capture test with a per-item date fails.

## Gates + proof

`flutter analyze` zero issues; full suite green (baseline +2382 ~2). Device
proof: Jeff records *"Add to my to-do list, call the dentist on Friday and
pay the water bill tomorrow"* → two to-dos, chips **Fri Oct 2** and **Mon
Sep 28**; server rows carry those `due_date`s; Google shows both dates.

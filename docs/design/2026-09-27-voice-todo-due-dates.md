# Voice to-do due dates — design (2026-09-27)

Jeff's first real voice capture produced the to-do
`for September 30th to go to the store` (recording transcript, verbatim:
`Add to my to-do list for September 30th to go to the store.`). The date
phrase should have become the item's due date, not its text.

Ships as **v1.26.0**, client-only (the parser is pure Dart; `due_date`
already syncs and already reaches Google Tasks as `due`).

## Jeff's picks (recorded)

- **D1 Only at the front.** A date phrase directly after the trigger
  applies to EVERY item in that sentence. A date phrase inside an item
  stays as item text (no per-item dates this arc).
- **D2 Next occurrence, up to a year out.** A month+day with no year is
  the next such date on or after the recording day: said on Sep 27,
  "September 30th" = this Sep 30; said on Oct 5, = next year's Sep 30.
  Never a date in the past. An explicit year is used as spoken.
- **D3 Dates only.** Month+day and numeric forms. NOT today / tomorrow /
  weekday names / "next week" / "in 3 days" — those stay text for now.

## Parsing rules (extend `TodoVoiceParser`)

After the trigger match and BEFORE splitting on separators, look for one
leading date phrase at the head of the span:

```
^[.,;:!?…\s]*            (Whisper's ". " after the trigger — already stripped)
(?:for|on|by|due(?:\s+on)?)?\s*     optional preposition
(?:the\s+)?
<DATE>
[.,:]?\s*                 trailing punctuation the phrase carries
(?:to\s+)?                the "to" of "to go to the store" — existing _leadingTo
```

`<DATE>` accepts, case-insensitive:

| Spoken / transcribed | Example |
|---|---|
| Month name (full or 3-letter, optional `.`) + day (1–31, optional `st/nd/rd/th`), optional `,? year` | `September 30th`, `Sept. 30`, `Sep 30, 2027` |
| `the <day><suffix> of <month>`, optional year | `the 30th of September` |
| Numeric `M/D` or `M/D/YYYY` (also `-`) | `9/30`, `09/30/2027` |

Resolution (`resolveSpokenDate(match, DateTime recordedOn)` → `String?`
ISO `YYYY-MM-DD`):

- explicit year → that date; if it is not a valid calendar date (Feb 30)
  → **no date, phrase stays text** (never guess).
- no year → candidate in `recordedOn.year`; if candidate < `recordedOn`
  (date part only) → `year + 1`. Feb 29 with no year → next leap
  occurrence within 4 years, else no date.
- `recordedOn` is the recording's `created_at` (the dump row), NOT
  `DateTime.now()` — a recording transcribed days later still means the
  date it was spoken on. Pass it in; the parser stays pure.

When a date is recognised:

- the phrase (with its preposition, "the", and the following `to`) is
  removed from the span; parsing continues exactly as today;
- **every** item from that transcript gets `due_date = <ISO>`.

When no date is recognised, output is byte-identical to v1.23.1 — this is
a hard test (the whole existing parser suite runs unchanged).

New public shape:

```dart
class VoiceTodoParse {
  final List<String> items;
  final String? dueDate;   // ISO YYYY-MM-DD or null
}
static VoiceTodoParse parseWithDate(String? transcript, {required DateTime recordedOn});
static List<String> parse(String? transcript) => parseWithDate(...).items;  // unchanged
```

`captureVoiceTodos` gains `required DateTime recordedOn` (callers pass the
dump's `created_at`) and calls `repo.add(item, dueDate: parse.dueDate, …)`.

## Real-data fixtures (must be in the tests verbatim)

1. `Add to my to-do list for September 30th to go to the store.` recorded
   2026-09-27 → `['go to the store']`, due `2026-09-30`.
2. Same transcript recorded 2026-10-05 → due `2027-09-30`.
3. `Add to my to do list. Go to the store and go get Advil.` (the v1.23.1
   fixture) → unchanged: `['Go to the store', 'go get Advil']`, due null.
4. `Add to my to-do list, pick up milk and call the dentist on Friday`
   → `['pick up milk', 'call the dentist on Friday']`, due null (D3: weekday
   stays text; D1: not at the front anyway).
5. `Remind me to on the 30th of September renew the plates` →
   `['renew the plates']`, due `2026-09-30`.
6. `Add to my to-do list for 9/30 get the oil changed` → due `2026-09-30`.
7. `Add to my to-do list for February 30th call the bank` → `['call the
   bank']`? NO — invalid date means the phrase stays TEXT: `['for February
   30th call the bank']`, due null.
8. `Add to my to-do list for September 30th 2027 buy tickets` → due
   `2027-09-30`.

## Tests

- `todo_voice_parser_test.dart`: the eight fixtures above + a table of
  month spellings (`Sept`, `Sep.`, `september`) + suffix variants + the
  D2 boundary (recorded ON the date → that date, not next year).
- `todo_voice_capture_test.dart`: captured rows carry `due_date`; a
  transcript with no date leaves it null; `recordedOn` comes from the dump
  row.
- Grouping: a voice todo with a due date lands in the dated section
  (existing `todo_grouping` tests cover the rule; add one row with
  `source='voice'` to prove nothing filters by source).

## Sabotages (each must fail one named test, real output quoted)

- S1 resolve with `DateTime.now()` instead of `recordedOn` → fixture 2
  fails (or fixture 1, depending on the day — the test pins both).
- S2 drop the `< recordedOn → year + 1` rule → fixture 2 yields
  `2026-09-30`.
- S3 apply the date to only the first item → a two-item fixture with a
  leading date fails on item 2.
- S4 accept Feb 30 (no validity check) → fixture 7 produces a date.
- S5 strip the phrase but forget the trailing `to` → fixture 1 yields
  `['to go to the store']`.

## Gates

`flutter analyze` zero issues; full suite green (baseline +2345 ~2). One
real-data proof: on a device, record "Add to my to-do list for October 3rd
pick up the dry cleaning" → the to-do appears under **Oct 3** (date chip)
with text `pick up the dry cleaning`, and within 5 minutes the Google task
shows the same due date.

## Not in this arc

Relative dates (tomorrow, Friday, next week, in N days) — D3. Per-item
dates — D1. Times of day. Re-parsing existing to-dos (the one already
captured stays as-is; Jeff edits or deletes it).

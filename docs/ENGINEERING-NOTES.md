# Tangent engineering notes

Hard-won operational knowledge for this codebase, accumulated across many
sessions of real device work. Every entry here was paid for with a failure.
Read this before changing build, storage, sync, migration or test code.

Originally maintained as an agent skill; exported verbatim for handover.

---


# Tangent app development

## On-device DB verification

The client DB is `app_flutter/tangent.sqlite` (NOT `databases/`). Pull it with
`adb exec-out run-as dev.tangent.tangent cat app_flutter/tangent.sqlite > out.sqlite`
— plain `adb shell run-as ... cat` corrupts the copy (CRLF translation inflates
it; sqlite3 reports 'database disk image is malformed'). Compare byte size with
`ls -la` on device to confirm a clean pull; read the copy with Python's sqlite3
(no sqlite3 CLI exists on device or host). This is the fastest ground truth for
schema/migration checks after an install: `PRAGMA user_version`, column
presence, row counts. Binary-safe transport alone does not ensure a consistent
SQLite snapshot: check journal mode and WAL companions. A live main-file copy
can omit committed WAL changes; use a consistent backup or a safely quiesced
capture of the database and its matching WAL. Do not force-stop during capture
or finalization, and never push a verification copy back over user data.

## Never pipe long commands through tail

`cmd 2>&1 | tail` destroys evidence twice: the exit code you see belongs to
tail, and the error text is gone. Run `cmd > log 2>&1; echo EXIT=$?` then grep
the log. This burned a 28-min Docker build diagnosis and nearly passed a
failing test suite as green in the same session.

Jeff's voice-recorder app. Repo `C:/Users/Jeff/Documents/ADH2`: `client/` (Flutter +
Kotlin Android) and `server/` (FastAPI + faster-whisper in Docker, container
`tangent-server`, host port 8765). Feature work happens in git worktrees under
`.worktrees/`. Package `dev.tangent.tangent`. Two test devices may be attached at
once — a Samsung Fold (`<fold-serial>`) and a Galaxy Tab S10 FE (`<tab-s10fe-serial>`,
`SM_X520`, active EMR pen). Always pass `adb -s <serial>`; an unqualified `adb`
command fails or, worse, targets whichever device is listed first.

## Verification standard (non-negotiable here)

Jeff wants proof, not claims. Run the real gates yourself and quote real output:
full `flutter test`, `flutter analyze`, server `pytest`, and the Kotlin JVM tests
when native code changed. Never report a subagent's self-summary as verified fact.

Require real end-to-end execution before declaring an integration works. Unit
tests written against hand-constructed library objects pass happily while the
library's real return shape differs — that gap has shipped multiple silent
failures in this project. Execute against the actual dependency once.

Before writing a test against an unfamiliar harness, open an existing passing
test that already drives the same production entry point and mirror its setup
verbatim — or import its helper outright (`import '<other>_test.dart' show
saveWith;`) rather than re-deriving a lease/save sequence that already exists.
Check WHERE the helper is declared before planning to import it: a `mountEditor`
defined inside `void main()` is a local closure over the file's own `setUp`
state and cannot be imported at all, so inventing a shared `*_harness.dart` to
hold it is a detour that ends in a missing-file error. Add the new cases to the
file that already owns the harness instead; only genuinely top-level helpers
(the `test/support/` factories) are importable. Composing the harness from memory burns cycles on invented helpers and
guessed types; in this repo the outcome variants are `Ok`/`Fail`, `IoOperation`
is a class with `id`/`result`/`settled` rather than a record, and a lease is
released with `close()`.

Grep for the real symbol before naming any type, fixture factory, column,
enum accessor, or WIDGET FINDER you have not just read — a plausible name is
wrong far more often than it feels. Finders fail in a particularly misleading
way: read the widget that renders an affordance before writing a finder for it,
because a guessed `find.byTooltip('Add text')` against what is really a
`PopupMenuButton` with items labelled `Text block` produces a finder miss that
reads as the feature being absent rather than as a wrong name — and the
affordance's TYPE decides the interaction the test must perform (open the menu,
then tap the item). Model-layer names in particular do not follow the guessable
pattern (the lease type is `UseLease`, a dump's size column is
`audioSizeBytes`, the mode's wire string is `wireValue`), and a test fixture's
constructor may be a sync factory rather than the async one the call site
suggests. The compiler catches each guess, but one `grep -n "class <Name>" -A`
is cheaper than a build round trip, and a wrong guess inside a test harness can
look like a product bug instead of a naming error.

When a feature degrades gracefully on error, a wiring bug looks identical to
"nothing to do." Treat any always-empty result as unproven until you have seen
the success path produce real output.

After adding a public method, grep for its call sites before believing it works.
An implemented, unit-tested method with zero callers is the default outcome of
parallel work and passes every gate while doing nothing at runtime.

Wait for BOTH `flutter test` and `flutter analyze` before committing. Tests
finish first; committing on test-green alone lands lint debt that the very next
analyze surfaces.

For performance work the same standard applies: quote a measured before and
after from the device. Never describe a change as a speedup you have not timed.

A test that has never been seen to fail is not a guard. Prove any test that
encodes a fix by sabotage: revert the fix, watch that test fail, restore the
fix, watch it pass — then report both outcomes. This costs two runs and is the
only evidence that the assertion tracks the mechanism rather than restating the
implementation. For performance and call-budget tests, assert the fallback path
in the same file too, so a caller that opts out of the fast path is provably
unchanged.

Verify the sabotage EDIT LANDED before trusting its result. A find-and-replace
that no-ops, matches the wrong anchor, or DUPLICATES a block instead of
replacing it leaves a working copy in place: the suite passes and you record a
false "this test is weak". Assert on the mutated source, not on the patch
tool's success flag — grep a marker and print its presence or count beside each
result:

```text
BASELINE:   guard=True    7 passed
SABOTAGE:   guard=False   5 passed, 2 FAILED   <- edit provably landed
RESTORED:   guard=True    7 passed
```

For multi-line mutations, edit the file directly and `assert sabotaged !=
original` rather than chaining patch calls whose misses are silent. Match on
the file's real line endings — an LF search string never matches this repo's
CRLF sources, and the miss reads as a passed sabotage.

The failed RESTORE is the dangerous half of that. A restore that reports
failure leaves the tree MUTATED, so every later edit, gate and commit runs
against sabotaged source. Assert the marker is back before moving on, and
prefer the fuzzy-matching patch tool over literal string replacement for these
CRLF files. Restoring can also hit an AMBIGUOUS anchor when a sibling method
legitimately shares the mutated shape (an `_add<Thing>` helper next to the
`_split<Thing>` under test); include enough surrounding context to make the
match unique rather than reaching for `replace_all`.

A sabotage that fails to COMPILE proves NOTHING — the tests never ran. Swapping
a value for one whose symbol the file does not import yields `Undefined name` /
`the Dart compiler exited unexpectedly`, the run reports failures, and it looks
exactly like a guard doing its job. Read the actual failure text and require an
assertion (`Expected: X / Actual: Y`) before recording a sabotage as passed.
Prefer mutations that stay compilable — substitute a plausible WRONG value, not
a missing one — and prefer sabotaging a layer whose symbols are already in
scope (the catalog's use of a helper) over the wiring line that needs a new
import.

A sabotage that PASSES means one of four things, in the order worth checking:
the guard test never RAN — `--plain-name` filters on the test TITLE, so a test
named for its subject rather than for the key it presses is silently skipped
and only the reported test count reveals it, so check that count against the
number of tests you meant to exercise before reading the verdict; the edit did
not land; another code path reaches the same result so the test
cannot distinguish them (probe what the system actually did rather than
guessing twice, then strengthen the test); or the guard is genuinely redundant
— two mechanisms each sufficient alone, in which case remove BOTH and confirm
the failure, and write that finding into a comment on the test instead of
claiming coverage you cannot demonstrate. Redundancy on a destructive action is
legitimate; an unexamined pass is not.

Weak-test tells: a fixture that takes an early-return path (an empty
collection, a single item) never reaches the logic the test names, and an
assertion that only checks "is this field null now" cannot separate "cleared
correctly" from "never set". Populate the fixture so the branch is entered, and
include a neighbouring item that must be left untouched.

An assertion comparing two measured DIMENSIONS is vacuous whenever the fixture
makes them trivially equal. "The backdrop covers the whole scrollable page"
proves nothing on an empty document, because the page is sized to exactly one
viewport until content extends it — both sides read the same number for the
wrong reason. Size the fixture so the two quantities MUST differ (place a block
far down the page), and assert that difference explicitly in the same test, so
a future fixture change cannot quietly restore the vacuous case.

A loop that reuses ONE stateful harness across cases tests that harness's state
guard rather than the rule under test. Iterating reservations against a single
catalog fails from the second pass with `Recording or finalization is active`,
because only one capture may be live at a time — and the failure reads as a
product bug in the rule being pinned. Build a fresh harness per iteration and
close it in a `finally`.

Before changing behaviour that is already observable, write characterisation
tests that pin what the code does TODAY, including the part you consider a bug.
They make the behaviour change visible in the diff, and they catch the case
where the current behaviour was not what anyone believed it was.

A doc comment describing behaviour is not evidence that the behaviour exists.
A guard clause added above it can render the documented branch unreachable
while the comment still reads as a specification — verify with a test before
building on any claim a comment makes about input handling or dispatch.

Measure to the user-visible finish line, not an internal one. "Row committed" or
"future resolved" is a stage boundary; the user's number ends when the screen is
interactive again. Publishing a fast internal timing as the answer to a
sluggishness complaint has been wrong here more than once.

Size the fixture to the real workload before believing a timing. Costs that
scale with recording length, file size, or item count are invisible on a
six-second test clip and dominate on real data — if Jeff reports a hang you
cannot reproduce, suspect your fixture before doubting his report.

When a platform API reports success, verify the EFFECT at the OS level before
claiming the feature works. A setter that returns cleanly, persists a
preference, and updates the UI can still change nothing about what the hardware
actually does.

## Diagnosing a silent hang

When an async path stalls with no error and no log, stop theorising and build an
instrumented APK with `print()` between every `await` in the suspect sequence,
then read `logcat -d | grep <TAG>`. The trace names the exact await that never
returned. Three plausible theories (broadcast-stream `asFuture`, `FileMode`
seeking, gain maths) each survived reasoning and died on contact with the
device; the probe found it in one run.

**package:record's PCM stream never closes on stop (Android).** `await
subscription.asFuture()` after `recorder.stop()` hangs forever on a Galaxy Tab
S10 FE — no error, nothing logged, spinner up indefinitely. Wait on the
stream's done event with a short timeout instead; that timeout is the NORMAL
path, not a safety net. Never `cancel()` without draining: it discards chunks
already emitted and truncates the tail.

**SAF renames files whose MIME disagrees with their extension.** AOSP's
FileSystemProvider APPENDS a MIME-derived extension when the display name's
extension conflicts with the declared MIME: `.wav` + `audio/ogg` published
`<id>.wav.oga` at 0 bytes — unplayable and invisible to the app's own lookup.
Derive the MIME from the suffix and keep any temp-file extension map agreeing.

**FileMode for patching a WAV header: append, not write.** `FileMode.write`
TRUNCATES the file and destroys the audio; `FileMode.append` both preserves
existing bytes and honours `setPosition()`. Probe before changing a file mode —
the intuitive choice is the destructive one.

**A downstream symptom can vanish with its cause.** The zero-length WAV header
was not a second bug: the header patch sat after the hung drain and was never
reached. Fix the blocker before chasing what follows it.

## Proving a recording actually saved

Exit codes and "a file exists" prove nothing. Pull the bytes with `adb exec-out
cat <path>` and assert RIFF size == len-8, data chunk == len-44, data > 0, then
check peak/RMS for real audio rather than silence. Finish on-device: playback
in-app plus a transcript is the only end-to-end proof.

Count Kotlin tests from `client/build/app/test-results/testDebugUnitTest/*.xml`
with ElementTree — `:app:testDebugUnitTest` exits 0 on an up-to-date no-op, and
reading only the first 400 chars of the XML misses the count attributes.

A drain/timeout test that passes because the helper's own timeout fired is a
hang wearing a hat. Assert on elapsed time (`Stopwatch` + `lessThan`) so it
distinguishes "noticed the close" from "waited out the clock", and sabotage with
the exact pre-fix line to confirm it genuinely fails.

A `terminal` call with timeout > 600s silently becomes a background process; its
notification can later report an OLD count against a since-edited file. Re-run
in the foreground before trusting it.

`--plain-name` filters by TEST TITLE, and a sabotage that "passed" may simply
not have run the test that guards it. Confirm which tests actually executed —
the run's own test count is the cheapest check — before recording a sabotage as
weak. When a sabotage really does pass, probe what rendered (a temporary print
of the observed values) rather than theorising twice.

Do not sabotage by string replacement from `execute_code`: these sources are
CRLF, an LF search string silently no-ops, and the file is left mutated or
unrestored while the result reads as a clean pass. Use the patch tool, then
grep a marker to prove the edit landed AND that the restore landed.

`search_files` has returned empty for paths that demonstrably contain matches.
Treat a universal-absence result as a tooling failure until cross-checked with
`grep` in `terminal`.

## Shipping honestly

Jeff would rather have a missing feature than a lying one.

- If a control cannot actually do what its label claims, remove it from the UI
  and explain the omission in the surrounding copy — never leave a setting that
  stores a preference while the system quietly does something else. Hiding ships
  as a real, tested change, with the working-but-insufficient layer retained
  underneath and the blocker written down for the next iteration.
- Retract a claim the moment evidence contradicts it, in the same message,
  before building anything on top of it. A waveform carrying real audio proves
  audio — not audio from the device that was selected.
- State which of "works", "partially works", and "does not work" applies to each
  item, and name the evidence for each. A completion report that smooths a
  failed item into the success list is worse than no report.
- When one shared picker/sheet is reused for several kinds of content, pass the
  kind through to its heading and search hint. A correctly filtered list under a
  generic heading reads as the wrong list having opened, and tests that assert on
  the DATA handed to the widget never see the words on screen — check the
  rendered label too, or read it off the device.
- Present a theory as a theory until the symptom is reproduced. Naming a
  mechanism, shipping a change for it, and reporting the symptom fixed is the
  same failure as any other unverified claim; if the change is worth keeping on
  other merits, keep it and say plainly that it did not explain the report.
  Retract in the same message that carries the disproof, and say what the cause
  actually was — a correction deferred to the next message reads as the earlier
  claim having stood.
- Re-verify a number before reporting it when the measurement has a known false
  positive. Quoting a count straight from a command whose own text can match the
  pattern it greps for turns a healthy result into a reported defect; pull the
  underlying detail and confirm there is something real behind the number.
- End a status report by saying WHO DOES WHAT next. A report that finishes with
  a bare command block reads as a request for Jeff to run it, and he has to ask
  what is actually being asked of him. Split the close into "mine to finish, no
  input needed" and the one decision that is genuinely his — then recommend an
  option rather than listing choices neutrally.
- Disclose a half-applied edit in the same message that reports progress. An
  interruption partway through a multi-site conversion leaves the tree with some
  callers changed and no gate run; a tidy-sounding summary implies a consistency
  that does not exist. Say which sites are converted, which are not, and that
  nothing has been verified yet.
- Do NOT commit a feature whose device verification FAILED, however green the
  gates are. Green tests plus a broken device behaviour means the fixture is
  wrong, so committing buries a known defect behind passing evidence. Leave the
  work uncommitted, name the defect, and say which suspect you would probe
  next — then commit the separately-verified work so it is not held hostage.
  When a session ends mid-diagnosis, state plainly that the cause is NOT
  diagnosed rather than offering the leading theory as the answer.

## Integration seams (the dominant bug class here)

Every layer in this app has been individually correct while the connection
between layers was missing. Assume the seam is broken until proven otherwise.

- A new parameter with a DEFAULT value makes the compiler silent about every
  construction site that does not pass it. Both halves of a feature can be
  individually correct and fully tested while the providers that build them
  never hand the value across, so a new control saves a preference that nothing
  reads — the exact lying-setting shape this project refuses to ship. After
  adding a defaulted parameter, grep the construction sites and wire them in
  the same commit, or make it required and let the build enumerate them.
- A screen that persists user data must call the composed service that writes
  the row AND publishes the durable file, not the bare repository. Check every
  mutation path separately — save and delete are wired independently, and a
  delete that skips publication leaves an orphan file that the next import
  resurrects.
- When a test double stands in for a composed service, assert on the
  composition's observable effect (the published file, the adopted row), not on
  the inner collaborator's call log. A fake repository records the save whether
  or not publication happened, so it passes while the seam is severed.
- A stateful widget holding a working copy of a prop and publishing edits
  upward gets its OWN edit echoed back when the parent setStates and rebuilds
  it. If `didUpdateWidget` reads any changed prop as a new document and resets
  or cancels the in-flight interaction, the widget kills its own gesture after
  the first edit: a drag erases one item then goes dead, a stroke is cut short
  mid-draw. Detect the echo by IDENTITY of the elements — the parent copies the
  list, so the container always differs while the elements are the same
  instances — and ignore it; re-seed only for a genuinely different document.
- Drive a controlled widget's test through a `StatefulBuilder` that feeds the
  callback's output back as the next props, exactly as the real parent does. A
  harness passing a FIXED list that never echoes cannot reproduce the parent's
  rebuild, so a gesture bug of the shape above passes the whole suite and fails
  on the first real finger. Any widget whose parent owns its state needs at
  least one echoing test before its feature is called done.
- Widget-test gestures do not resemble fingers, and this gap has shipped three
  separate notebook bugs that every gate passed. `tester.tap()` moves EXACTLY
  zero pixels while a real finger always slides a pixel or two before lifting,
  so a recognizer that claims a drag on any `PointerMoveEvent` swallows every
  real tap while the suite stays green. `tester.drag()` emits ONE move event
  covering the whole distance, so a threshold is crossed on the first event and
  a slow finger's stream of 1-3px moves is never exercised. For any
  tap-vs-drag behavior write both shapes explicitly: a tap that wobbles ~1.5px
  (`startGesture` then `moveBy` under the slop, then `up`), and a slow drag of
  many small `moveBy` steps with a `pump` between each. `createGesture(kind:)`
 sets the pointer kind, which is how stylus-vs-touch branches get covered
 without hardware, and `createGesture(buttons:)` covers a stylus side button —
 `TestPointer` propagates `buttons` across move events.
- `tester.sendKeyEvent(...)` simulates a HARDWARE key and proves nothing about
  the on-screen keyboard, which sends no key events at all. For anything the
  Enter/Return key must DO, drive `tester.testTextInput.receiveAction(...)`
  instead, and assert the field's `keyboardType`/`textInputAction` alongside
  it — a suite green on key events alone happily ships a field no tablet user
  can operate, and a handoff calling that "tested" is still unverified. See
  `references/soft-keyboard-and-text-input.md`.
 - A `StreamProvider` delivers its first value a frame AFTER the widget mounts.
 A harness with a single `pump()` renders against an empty list, so anything
 that stream feeds (folder sections, filter chips) is silently absent and the
 test reads as "the feature does not render". Pump twice before asserting.
 - Name the scrollable explicitly in `scrollUntilVisible` whenever a sheet or
 dialog sits over a list: two scrollables in the tree make the default finder
 ambiguous and it throws. `scrollable: find.descendant(of: find.byType(<the
 sheet>), matching: find.byType(Scrollable))`. Rows below the fold of a
 `ListView` are built lazily and genuinely absent from the tree, so
 `findsNothing` there is not evidence the widget was never added — it is also
 the signal that a user on a short screen must scroll to reach it. Do NOT
 scroll a MODAL bottom sheet at all: a drag on one is its dismiss gesture, so
 `scrollUntilVisible` closes the sheet and every later lookup dies with `Bad
 state: No element`, reading as the item never having rendered. A modal sheet
 is capped at 9/16 of the screen, so ONE added row can push the list past the
 fold and break a previously-passing test — give that test a taller surface
 (`tester.view.physicalSize` plus `addTearDown(tester.view.reset)`) rather
 than scrolling, since the claim under test is that each row renders, not
 that it survives a scroll.
- To pump a screen against one pinned controller state, `implements` the
  controller and extend the framework base (`class _Fixed extends
  StateNotifier<RecordingState> implements RecordingController`) instead of
  constructing the real one — these controllers take half a dozen collaborators
  they never touch while merely displaying a state. Declare every member the
  BUILD PATH reads, not only the one under test: a `noSuchMethod` fallback
  compiles fine and then throws `NoSuchMethodError ... has no instance getter`
  during build, in only the one state whose branch reads it (the timer's
  `elapsedSeconds` on the recording branch), which reads as a product bug in
  that branch. Match the provider's arity too — a `StateNotifierProvider`
  override takes `(ref) => ...`, a `NotifierProvider` override takes `() => ...`.
- Assert a screen's internal ORDER from what it RENDERS, not from its State.
  These State classes are private, and adding a `debugBlocks` accessor to reach
  one puts test scaffolding in production; read the keys in layout order
  instead (`tester.widgetList<Positioned>(...)` mapped to their `ValueKey`),
  which also survives a refactor of the backing list.
- Anchor a key-prefix matcher so sibling keys cannot inflate the match. A block
  keyed `notebook-block-<id>` shares its prefix with `notebook-block-grip-<id>`
  and `notebook-block-remove-<id>`, so `startsWith` counts three widgets per
  block and an "exactly one was inserted" assertion silently measures nothing;
  use a regex that terminates the prefix (`^notebook-block-[^-]`).
- Scope `find.byType(CustomPaint)` with `find.descendant(of: find.byType(<your
  widget>))`. Framework widgets (Scaffold among them) mount their own
  `CustomPaint`s, so `.first` returns one whose `painter` is null and the test
  dies with a `_TypeError` that reads like a bug in the widget under test. The
  same holds for every common wrapper the framework also uses — an `ancestor`
  finder for `IgnorePointer` matches several, so `findsOneWidget` fails on a
  correctly wrapped widget. Take `.first` on a scoped finder and then assert
  the PROPERTY that carries the meaning (`ignoring` is true), because the
  wrapper merely being present does not prove it is enabled.
- A `CustomPaint` placed in an unbounded parent (a `Row`, a scrollable's cross
  axis) is handed an INFINITE width, and any `(size.width / n).floor()` throws
  `Infinity or NaN toInt` during paint — a crash no unit test on the painter
  will produce. Give the widget an intrinsic size from its own content and
  guard the painter against a non-finite canvas. A spacing-driven paint loop
  needs the same guard against zero or negative spacing, which loops forever.
- Test a painter directly by driving `paint()` with a fake `Canvas` that
  implements only the draw calls under test and counts them, letting
  `noSuchMethod` THROW on everything else. That asserts what was actually
  drawn — line count per page height, nothing drawn in the disabled state, the
  infinite-canvas guard returning early — without pumping a widget, and the
  throwing fallback catches the painter reaching for a call the fake silently
  would have swallowed.
- Two gesture recognizers competing for one drag cannot be reconciled by tuning
  thresholds — that is an architecture bug, and three threshold fixes failed
  here before the design changed. Whichever accepts on the SMALLER threshold
  wins and REJECTS the other mid-gesture, which stops delivering it events at
  all; the loser's travel simply stops climbing short of its own limit. Make
  the competitor step aside instead: have the card tell the page to hold still,
  then let the uncontested recognizer use a small threshold. A scrollable that
  is handed `NeverScrollableScrollPhysics` drops its drag recognizer via
  `setCanDrag(false)`, leaving an empty arena.
- Signal that yield from `Listener.onPointerDown`, never from `onPanStart`. If
  the rival wins the arena, `onPanStart` never fires — so a fix hung off it is
  dead exactly in the case that needs it. `onPointerDown` precedes every arena
  decision.
- Keep a dedicated recognizer rather than a plain `GestureDetector` on a card
  that also has an `InkWell`. The plain detector loses the SECOND drag to the
  tap recognizer while the first still works — a signature worth recognising,
  since it reads as state corruption rather than a gesture conflict.
- When a drag works fast and fails slow (or vice versa), instrument the
  recognizer on-device and log travel distance, the computed slop, and accept /
  reject callbacks. Two runs at different speeds localise it in minutes;
  reasoning from the widget tree does not, because the deciding events never
  reach the code being read.
- To tell "my change broke this" from "this expectation was always wrong",
  `git stash push -- <file>`, re-run the failing test against the old code, and
  compare. A pass proves the regression is yours and, just as usefully, proves
  the intermediate values the old code produced were correct.
- Before splitting, renaming, or re-pointing a Riverpod provider, grep the test
  tree for `<provider>.overrideWith`. Overrides silently stop covering a
  consumer that now awaits a different provider, and the real body runs and
  throws `UnimplementedError: Override in main()`.
- An override that performs real setup (installing the default storage
  location) cannot become a no-op when a provider is split; move it to the half
  that genuinely needs it, or dependent operations fail with 'No default
  recording folder'.
- Screens must read a dedicated data provider, never a raw database or service
  provider. `ref.read(localDbProvider)` inside `build()` throws
  `UnimplementedError: Override in main()` in every widget test — harnesses
  override PROVIDERS, not the database — and it reds the screen's entire test
  file at once. Add a provider beside the one the screen already uses
  (`foldersProvider` next to `notebooksProvider`) and let tests override it.
  Extracting ordering/grouping rules into a pure function outside the widget is
  right, but a passing pure-function test proves nothing about rendering: pump
  the real screen as well.
- An enum state that no screen branches on renders as whichever neighbour the
  build method falls through to. `RecordingState` carried `starting` and
  `saving` while the home screen tested only `recording` and `idle`, so both
  working states painted an idle screen. After adding a state, grep the screens
  for the enum and confirm every variant reaches a branch. A variant added to
  a SHARED enum (a list-item action several screens dispatch on) additionally
  breaks exhaustive `switch` statements in screens unrelated to your change;
  `non_exhaustive_switch_statement` is a compile error so analyze names them,
  but expect the blast radius to include files you never opened.
- Give every non-instant operation a visible busy state, and treat that
  indicator as an INSTRUMENT rather than decoration. While work-in-progress
  renders as idle, a hang, a rejected save and a dead control all present
  identically and each theory costs a device round trip; once a spinner is on
  screen, "still spinning minutes later" separates a hang from a fault at a
  glance. Refuse input on the control that started the work — tapping through a
  finalising save starts a second capture before the first has committed, which
  is how orphaned staging files appear.
- When making a flag one-shot, grep for every writer, not just the reader.
  Clearing it where it is consumed is defeated by an unrelated path re-setting
  it on the next launch.
- Hoist directory enumerations out of per-item loops. On SAF each enumeration
  is a native round trip, so a `preview()` inside an adoption loop is O(n^2)
  native I/O that reads as a hang.
- Decide "is this item excluded?" with the SAME filter that builds the list, by
  testing absence from the filtered result — never by re-deriving the verdict
  from a stored display string. A persisted label is whatever the picker showed
  at the time and need not contain the token being grepped for, so a
  label-sniffing check passes its tests and fails on the device.
- A fire-and-forget platform call cannot influence a resource that the very next
  call binds. When an async side effect must be in place before an operation,
  trigger it at an earlier natural user moment (selection, app resume) and keep
  the operation itself non-blocking — do not convert a hot path into an await.
- Track what an idempotent platform call has already applied. Without that
  state, an earlier warm-up and the call site both fire; a test asserting the
  call log catches it as a duplicate.

## Storage / SAF publication rules

The Android SAF publication layer is the most defect-prone area of this codebase.
Every bug found here had the same shape: the happy path worked, the failure path
lost data.

- Never delete the previous published file before the replacement is safely
  renamed into place. Park the old copy under a temp name and delete it only
  after success; restore its name on any failure. Providers do refuse renames.
- Keep temp file names MIME-coherent (`.partial.json`, `.partial.md`,
  `.partial.ogg`). AOSP's FileSystemProvider renames temps whose extension
  mismatches the declared MIME, which corrupts created-identity checks.
- Treat native document IDs as opaque. Resolve nodes by enumeration and the
  provider-issued locator; never parse a document ID as a filesystem path.
- A durable save followed by a cleanup or publication fault is NOT a lost save.
  Report it truthfully without telling the user their data vanished.
- When adding a new content kind, extend the native mode allow-list and the
  suffix/MIME helper together. A mismatch yields `Invalid reservation staging
  path` and a failed save that leaves no row.
- The document publication port is TEXT-ONLY: content crosses as a String and
  the native side encodes it UTF-8 then verifies readback against those bytes,
  so binary is corrupted AND fails the readback. Binary needs its own port
  method and native entry point — never base64 through the text one, because
  the published file must be directly usable in the user's folder rather than
  an encoded blob. Have both entry points share ONE private write routine so
  the atomic temp -> verify -> park -> rename -> delete sequence cannot drift.
- Attaching content to an EXISTING row is publish -> attach -> bind, in that
  order, and the capture-reservation path cannot do it: `reserveCapture` mints
  a fresh id and rejects any id already in dumps/bindings/tickets/
  reservations, while a synced row keeps the server's id. `bindRecording`
  verifies the row's audio path ALREADY equals the binding locator ('Original
  audio identity differs' otherwise), and playback resolves through
  `recording_bindings` (bindRecording faults 'Original audio identity differs' at local_db.dart:967 unless audio_path already matches) — so a
  file written with a path but no binding looks available and refuses to open.
  See `references/storage-publication-port.md`.
- Durable user files live in the user-selected folder, one subdirectory per kind
  (text notes and notebooks each get their own child directory). Import
  re-adopts them; newer timestamp wins, local wins on ties.
- A restored native operation the native side no longer retains must settle as
  failed, not poll forever. An endless 50ms poll loop pinned a capture fence and
  got the app killed for excessive CPU, presenting as a dead record button.
- Zero-byte orphan temp files accumulate and make startup import re-scan them
  endlessly. Clean only dot-prefixed zero-byte `.partial` files, never by name
  pattern alone.
- Fix repeated enumeration by narrowing the QUESTION, never by caching the
  directory. This layer re-verifies deliberately so a save survives a crash
  mid-write, and a snapshot cache fights that design: stale reads surface on
  device as intermittent "recording failed to save". A cache also creates two
  readers of one directory — a live inventory and a cached node lookup — which
  disagree the instant a file is created and fault an otherwise correct
  publication.
- Extend the storage port with an OPTIONAL narrow operation instead of changing
  the existing one: return null/Unsupported by default so any backend that
  cannot answer keeps using the listing, and have the fast path and the listing
  share one decoder so a single-entry read can never disagree with the listing
  about what an entry means. Keep the guarantee intact — membership proved by
  building the child URI through the granted tree, an absent or unproven entry
  still faulting. Local filesystem backends should opt out explicitly: a
  directory listing is one cheap syscall there, unlike a SAF round trip.
- Bring an imported/external file in through the SAME reserve → staging →
  publish path a live capture uses, never by writing into the destination
  folder directly. That path is what confers the ownership checks, atomic
  publish and crash-safety; a file dropped straight into the folder is adopted
  by scan with none of them. COPY the source and leave the user's original
  untouched, validate size/existence BEFORE reserving so a bad pick costs
  nothing, and on failure delete the staging file and its reservation row so a
  retry is not blocked by a half-made capture. Disable import while a capture
  is active — both contend for the same reservation machinery.
- A staged capture whose reservation carries NO publication receipt is not
  recovered by the app's own startup path: recovery matches on
  `publication_json`, so an `interrupted` row with a null receipt keeps its
  audio on disk and its reservation open indefinitely. Force-stop, relaunch,
  and re-count the staging directory before telling the user anything will heal
  itself — and bring such files back through the normal reserve → staging →
  publish path rather than copying them into the library folder.
- Copy a picked `content://` document into app-private storage on the native
  side and hand Dart a plain path. A transient read grant can expire partway
  through a multi-stage import, and timestamping the cached name keeps two
  files with the same display name from colliding.

## Audio capture (package:record)

- The plugin exposes NO numeric gain. Its only knob is a boolean `autoGain`
  AGC whose own docs warn recording volume may be LOWERED — an automatic
  leveller, not a sensitivity control. A percentage slider mapped onto it would
  store a preference while the system did something else.
- `startStream` emits ENCODER output, not raw samples, and stream mode writes no
  file of its own. Amplifying therefore means `pcm16bits` + owning the WAV
  container yourself, which also means the file is WAV rather than Opus (~8x
  larger). Keep unity gain on the existing encoded path so the default install
  is byte-identical and only an opted-in user pays the storage.
- Scale samples with a SATURATING clip. Plain integer arithmetic WRAPS SIGN past
  the rail and is heard as violent crackling, far worse than the clipping it
  replaces. Pass a trailing odd byte through untouched — a stream chunk can
  split a 16-bit sample, and dropping that byte shifts every later sample into
  noise.
- A streamed WAV's header is written before any audio exists, so both length
  fields start at zero. Patch them on stop or the file is complete on disk and
  plays as a fraction of a second.
- `cancel()` on the PCM subscription DISCARDS chunks the platform already
  emitted but has not delivered, silently truncating the tail. Stop the recorder
  first, then let the stream drain. Release the sink and subscription in
  `dispose()` too, or the staging file stays locked against the next
  reservation.
- When two subsystems must agree on a capture decision (the recorder choosing
  stream-vs-file, the reservation naming the staging file), export ONE predicate
  and have both read it. Two independent comparisons drift, and the failure is
  raw PCM written into a file named `.opus` — unplayable and untranscribable.
- A content extension that stops being a pure function of the capture MODE has
  to be re-derived everywhere at once. `contentExtensionForMode(mode)` is
  called independently from staging validation, the publication codec, the
  filesystem backend and the SAF port; each expects `.opus` and rejects the
  `.wav` the recorder just wrote. Grep the helper BY NAME across `client/lib`
  and `client/android`. Counting the call sites from one grep of a single
  directory under-reports them — a partial conversion passes every gate and
  fails only on device.
- Those call sites split into two kinds, and treating them uniformly stalls the
  conversion. A site that HOLDS a reservation (staging validation, the
  publication codec, cleanup) switches to a helper taking the already-staged
  path. A site that holds neither mode nor gain — an owned-name check driven by
  a binding, the import scanner enumerating candidate suffixes — cannot derive
  anything and must instead WIDEN its allow-list to include the new suffix.
  Discovering a site that cannot be handed a reservation is the signal it needs
  a name-set change, not a harder refactor.
- A capture that fails partway leaves the recorder holding platform resources,
  so the NEXT capture fails too — including after the setting that caused the
  failure is reverted. When a start failure clears ONLY on app restart, that is
  wedged state, not a configuration problem: release everything the start path
  acquired on every failure branch, and diagnose from a freshly launched
  process so a stale wedge is not read as a second bug.

## Multi-device sync

### Keep recording and notebook acceptance separate

Never infer recording sync from notebook convergence, server entity allow-lists,
or green component tests. Verify each entity through its real producers,
change feed, receiving database and receiving UI. Existing recordings require
backfill as well as publication of future upload/transcription changes. Prove
explicit audio download with actual bytes and playback; a metadata row is not
audio-transfer evidence. Metadata always syncs regardless of Wi-Fi-only;
Wi-Fi-only applies to explicit audio fetch. Do not announce all sync complete
until each promised path has independent end-to-end evidence.

For page-growth verification, an empty page plus swipes proves nothing: place
visible content below the original viewport and verify that content moves into
view with ruling still behind it.

The "sync through the Docker container" question is answered: the container IS
the hub — `tangent-server` on 8765, reachable over Tailscale, no third party.

Read `docs/design/multi-device-sync.md` before designing anything; its
decisions are already made. Server-assigned monotonic `change_seq` is a
CHECKPOINT, not a clock — assigned by a single authority, so device clock skew
is irrelevant BY DESIGN. Last-write-wins on `updatedAt` is REJECTED on
data-loss grounds: at whole-notebook granularity the loser's handwriting
vanishes because another device saved a title edit a second later.

The doc says SQLAlchemy; the server actually uses raw `sqlite3` with
`CREATE TABLE IF NOT EXISTS` plus migration helpers. Follow the code.

**Server side, phases 1-2, BUILT:** tables `change_log`, `devices`,
`notebooks`, `notes`; service `app/services/change_log.py`; router
`app/api/sync.py` exposing `POST/GET /v1/devices`, `GET /v1/sync/pull`,
`POST /v1/sync/push`. Merge lives on the CLIENT deliberately — the server
stores document bodies opaquely, so it never has to understand ink and a
client-side document change needs no server deploy.

Four rules there are load-bearing and each has a sabotage-proven test:

- A pull EXCLUDES the caller's own changes. Without it a device re-applies its
  own push over a newer local edit.
- Deletes TOMBSTONE (`deleted_at`), never remove the row — a row deletion on A
  is silently undone by B's next push.
- Push results are PER ENTITY. The client clears its dirty flag per entity, so
  a whole-batch rejection strands work that was perfectly acceptable.
- Push republishes what the server HOLDS, never the payload the device SENT.
  A device that lacks a resource omits its field, so echoing the submitted
  payload broadcasts that omission to the whole fleet — every other device is
  told the audio is gone while the file sits on disk. Re-read the stored row
  after applying and overwrite the server-owned fields in the published
  payload.

An entity type being ALLOWED by the change feed is not the same as anything
publishing it. Each ordinary CRUD route AND every background completion path
(a finished transcription, an upload handler) has to call `record_change`
itself; miss one and that entity silently never syncs while its own route
tests all pass. Grep the router for the publish helper and confirm one call
per mutating handler. An upload handler in particular must also set whatever
availability flag the feed reports, or the rest of the fleet reads a stored
false and hides the download.

**Client side, BUILT and VERIFIED on hardware:** schema v11 — v9 added the
dirty flag + synced checkpoint on notebooks, `sync_tombstones` and `sync_state`
(device identity); v11 added `sync_dirty`, `synced_seq`, `remote_only` and
`audio_on_server` to `dumps`, all NULLABLE (see the Drift non-nullable trap
below). Plus a `DocumentSyncEngine` doing pull → merge → push for BOTH
notebooks and dumps, the sync methods on `TranscriptionClient` including
`downloadAudio`, a shared `SyncButton`, and a WorkManager periodic task.
Proven end to end twice: a notebook made on the tablet appeared on the Fold,
and recording sync took the tablet 12 → 76 and the Fold 8 → 75 against the
live library (commit `c6924e9`). Tap-to-download audio is NOT built yet — the
route, the client method and the `audio_on_server` flag all work, but no
button calls them, and playback goes through the storage-binding/importer
layer so a downloaded file must be ADOPTED rather than written to disk.

Check whether a status column is LIVE before diagnosing from it. Every client
recording read `sync_status='pending'`, which looked like total upload failure
and was reported to Jeff as such — but that column is legacy and the current
engine never writes it. The real state came from comparing ids against the
server's `dumps` table, which showed every transcribed recording present with
its audio. Grep for writers of a status column before reading meaning into its
value; a column nothing writes is not evidence, and a confident wrong claim
built on one costs more than the check.

Prove a sync feature from the SERVER'S tables, not from the client UI. Reading
`devices` and `change_log` straight out of `server/data/tangent.db` gives origin
device, op and seq per change — evidence no screenshot can fake, and it needs no
API token. Screenshot the receiving device too, since "the row is on the server"
and "the other device shows it" are different claims.

Write a real-HTTP smoke test (`server/tests/smoke_sync_http.py`) that boots the
app on a socket against a temp data dir and drives the two-device flow. Unit
tests on both sides share fixtures and therefore share any misunderstanding of
the wire format; only a real request settles it. When it disagrees with the
client, read the server's Pydantic models before changing anything — here the
SERVER was right (`op`/`payload`/`head_seq`) and the smoke test was wrong.
Copy the existing smoke test's harness lines rather than re-deriving them —
uvicorn needs `app.main:create_app --factory`, readiness polls
`/openapi.json` because no `/health` route exists, and `/v1/setup` takes
`display_name`. Each wrong guess costs a full boot cycle to discover.

Assert a sync guarantee on the PULLED PAYLOAD, not on the stored row. A test
that reads the database directly and finds the right value passes while the
feed publishes something else entirely, because pull serves the recorded
payload rather than re-deriving it from the table. Any rule about what other
devices will LEARN has to be asserted through a real pull; a DB-level
assertion only covers what this server remembers. That gap hid a defect
through a green unit suite and surfaced on the first real-socket run.

New server endpoints do not exist for the device until the CONTAINER IS REBUILT.
The running image is not the working tree, so a green server suite plus a green
client suite can both pass while the device talks to an old image that has never
heard of the route. Back up `server/data/tangent.db` before the first start of
an image carrying new schema DDL: the bind mount survives the rebuild, which
means new `CREATE TABLE`/migration code runs against Jeff's real data on that
start. Expect the rebuild to take many minutes when base layers re-pull — run it
in the background with completion notification and do other work meanwhile,
rather than burning foreground timeouts on it.

Device identity has its own failure mode worth naming: `Platform.environment`
carries NOTHING on Android, so a label read from it always falls back and every
replica registers under the same name. Use `device_info_plus`. Nothing caught
this because no test constructed the engine and inspected what it SENT — a
recording fake asserting on the registration call is the guard, and sabotaging
the lookup must reproduce the exact wrong string. Treat naming as cosmetic in
the engine: wrap the lookup so a platform-channel failure cannot abort the sync
cycle.

A fake built on `noSuchMethod` returning a bare `true` silently satisfies a
method whose real return type is an enum (`ConnectivityService.currentStatus()`
yields `ConnectivityStatus`, not a bool), and the engine then reads the device
as offline — so every test in the file passes for the wrong reason. Declare the
members the code path actually calls and let `noSuchMethod` THROW.

Three client rules mirror the server's three and are equally load-bearing:

- Mark dirty on EVERY local write path, not just the obvious save. A sync
  engine with no dirty-marking call sites passes its entire suite while pushing
  nothing — the zero-call-sites outcome this repo produces by default.
- Record the tombstone BEFORE deleting the row. Delete first and nothing is
  left to derive a tombstone from, so the deletion never pushes and the other
  device resurrects the entity on its next sync.
- Clear the dirty flag only WHERE `updatedAt` still equals the value that was
  pushed. An edit landing while the push is in flight is otherwise marked clean
  and never syncs again.
- A synced field that IMPLIES a derived status column must set that column at
  the apply site. Transcript text arrived correctly on 37 recordings while
  `transcription_status` kept its table default, so the list showed "Not
  transcribed" on rows whose transcript was right there — the payload was
  perfect and the row was wrong. Unit tests passed because they asserted the
  synced FIELD; assert the derived column too, and both directions of it (text
  present => completed, absent => unchanged).
- Fixing an apply-side bug does NOT heal rows already synced under it. Their
  `synced_seq` is current, so the feed never replays those changes and the bad
  value persists indefinitely. Every apply-path fix needs a paired one-time
  reconcile for rows written before it, or the defect survives the fix on
  exactly the devices that hit it. Ship the reconcile as a DATA-ONLY schema
  migration (v12 was exactly this, no columns changed) so it runs once per
  device on next launch and needs no manual script against live device DBs.
  Leave `updated_at`, `sync_dirty` and `synced_seq` untouched in such a
  repair: a local correction is not a user edit, and marking the rows dirty
  pushes dozens of pointless changes per device and races the peer making the
  identical repair. Rehearse it against COPIES of the pulled device databases
  first and diff every column you are not intending to change (row count,
  transcript bytes, audio paths, timestamp sum, notebooks) — the on-device
  numbers should then match the rehearsal exactly, which is what turns
  "the migration ran" into proof it did only what it claimed.
- Scope a repair predicate by the CURRENT value, not only by the evidence.
  "Has transcript text" also matches a typed note (`not_applicable`, whose
  transcript column legitimately holds the note body) and a `failed` row whose
  partial text must keep its failure so the retry path still sees it. Requiring
  the status to be exactly the wrong value keeps both safe, and sabotaging that
  clause away is what proves the guards are real.
- SQLite's `TRIM()` strips SPACES ONLY — not newlines or tabs. A transcript of
  `"  \n "` passes a bare `TRIM(x) <> ''` check and gets treated as real
  content. Name every whitespace character explicitly:
  `TRIM(x, ' ' || char(9) || char(10) || char(13))`.
- A data-repair migration must PRAGMA-check the columns it touches, exactly
  like an additive one. Migrations run in sequence, so a step added at v12
  executes on a v7 database BEFORE the column it references exists, and a bare
  UPDATE throws `no such column` — which bricks app launch for the oldest
  installs while every fresh-database test stays green. A new test file that
  starts at the current version structurally CANNOT catch this; the 13
  pre-existing migration tests did. Run the FULL suite, never just the new
  file, after adding any migration step.
- Adding a field to the payload is a two-sided change, and the apply side is
  where data is lost. The remote-apply path writes with `InsertMode.
  insertOrReplace`, which rewrites the WHOLE row, so a field the peer did not
  send arrives null and erases a value this device already holds. Distinguish
  ABSENT from null explicitly — `payload.containsKey(k) ? payload[k] : null` —
  and have the apply method fall back to the currently stored value, so a peer
  running an older build degrades to leaving the field alone instead of
  clearing it across the fleet.

Scope: sync notebooks (ink + typed blocks + card refs), text notes, dump
metadata and transcripts. Do NOT sync audio — it stays on the recording device
and transfers only on explicit request. A dump present without its audio is a
first-class state, not an error. Build it as general project functionality:
"the sync is to be built for everybody, not a dedicated samsung tablet."

Jeff's settled choices for the client half: a sync button on the LIST screens
(Home, Dumps, Notebooks, Text Notes); metadata always syncs while only audio
fetch respects the Wi-Fi-only setting; a device names itself from the Android
model, editable in Settings.

Background cadence is WorkManager periodic plus Drift's existing `watch*`
streams for immediate local change detection — no file watcher is needed,
because the DB already emits reactive streams. Android's minimum periodic
interval is 15 minutes and the cadence is a GUIDELINE the OS batches under
Doze, so "every 30 minutes" must be described as approximate; promising exact
timing would be a lying feature. A `dataSync` foreground service is the wrong
tool here — Android 15 caps all foreground services at 6 hours per 24 — and
User-Initiated Data Transfer jobs (API 34+) back the BUTTON, not the timer.

The WorkManager callback runs in an isolate with NO providers and NO database
handle, so it must build its own — which is why the sync engine takes its
dependencies by injection. A dispatcher stubbed to `return true` registers,
wakes, and syncs nothing while every log looks healthy: that is the same lying
feature as a setting nothing reads, so write the real sync or do not register
the task. Mark the entry point `@pragma('vm:entry-point')` or release-mode
tree-shaking drops it and the task silently never fires. See
`references/background-work-and-sync.md` for the registration policy, the
isolate's return-value contract, and the rules for the result message.

## Notebook block insertion position

DONE: both toolbar inserts now land directly below the block being edited,
matching what Enter already did in `_splitCheckboxBlock`:
`..._blocks.take(at)` then the new block then `..._blocks.skip(at)`, leaving
x/y null so it flows beneath its source instead of landing on top of it at
identical coordinates.

Those three spreads are textually similar — a patch on the bare `..._blocks,`
fragment matches several sites, so include surrounding context.

**Focus cannot be read at the moment an inserting menu item is chosen.**
Opening a `PopupMenuButton` moves focus to the MENU, so a live scan of the
field `FocusNode`s at insert time always answers "nothing focused" and every
insert silently falls back to appending at the end — the exact bug being fixed,
surviving the fix. Record the last focused block id from a listener on each
node as focus ARRIVES, and clear it when that block is deleted so a stale id
cannot steer later inserts. Keep the no-focus fallback (append to the end) and
test it: there is no "here" to insert at, and moving the user somewhere they
did not ask to go is worse than appending.

When a framework-state assumption like that one fails, print the state at the
exact decision moment from inside the widget test (`focusNode.hasFocus` after
the tap) instead of re-reasoning about the widget tree. One probe run settled
what two rounds of plausible reasoning got wrong — the field genuinely held
focus, just not when the production code looked.

## Notebook page ruling

DONE and on device: `NotebookRuling` (blank / small / medium) plus
`NotebookRulingPainter`, persisted as a nullable `ruling` column and carried in
the sync payload. Jeff's settled choices: ruling SYNCS (it is a property of the
document, so the same notebook must not look different in each hand), new
notebooks default to RULED, and the lines sit statically behind content —
nothing snaps to them, because snapping ink would fight the pen.

Derive line spacing from real ruled-paper standards and the device's density
rather than picking it by eye: at 280 dpi the ratio is 1.75, so 1 mm is 6.3
logical px, giving narrow ruled 6.35 mm = 40 px and college ruled 7.1 mm =
45 px. Pin those numbers in a test so changing a preset takes a deliberate edit.

Paint the ruling into the SCROLLABLE SURFACE, not the viewport. A backdrop
sized to the visible area slides against the writing as the page scrolls and
runs out of lines at the bottom; filling the full-height `SizedBox` inside the
scroll view makes the ruling extend automatically as the page grows, because
the page height already tracks the lowest content. Wrap it in `IgnorePointer`
or the full-page layer silently eats pen strokes and card drags — the same
hit-testing hazard as any other full-bleed overlay.

Ink is NOT a block: strokes live in a separate `_strokes` list on the canvas, so
"insert below where the pen last wrote" has to derive a position from the last
stroke's bounds and then place it among the flow blocks. That is a product
decision about interleaving, not an implementation detail — ask before guessing.

## Toolchain quirks (Windows + git-bash)

- Write generated patches as RAW BYTES, never through a text-mode handle.
  Sources here are CRLF; `open(p,'w').write(diff)` rewrites line endings and
  git rejects the result with `corrupt patch at line N`. Use
  `subprocess.run(['git','diff','--binary'], capture_output=True)` and write
  `p.stdout` with `open(path,'wb')`. Then TEST-APPLY it: clone to scratch,
  check out the base commit, `git apply --check`, copy untracked files in,
  and run analyze plus the affected tests. A handover patch that does not
  apply is worthless, and the failure surfaces only in someone else's hands.
- The Android `gradlew` bash wrapper fails in MSYS. Run Gradle directly:
  `java.exe -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain :app:testDebugUnitTest --tests "..."`
  from `client/android`. JDK at `C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot`.
- Never read a piped Gradle run's exit code as the test result. Piping through
  `grep`/`head` reports the exit status of the LAST pipeline element, so a suite
  ending in `BUILD FAILED` still returns 0. Grep the captured output for
  `BUILD SUCCESSFUL` or `FAILED` and quote that line as the verdict.
- `BUILD SUCCESSFUL` alone does NOT mean tests executed — an up-to-date or
  NO-SOURCE task prints it happily. Quote a real test COUNT: parse
  `client/build/app/test-results/testDebugUnitTest/*.xml` for the `tests`,
  `failures` and `errors` attributes, and check the file mtimes are from this
  run. Add `--rerun-tasks` when a source edit must be re-exercised.
- Chain verification steps with `&&`, never `;`. A `;` lets the chain run on
  past a failed step, so an `echo "exit=$?"` after it reports the echo's own
  success and a suite that never executed is filed as green. Assert on positive
  evidence — the printed test count — not on a trailing exit code.
- A foreground `terminal` call whose timeout exceeds 600s is converted into a
  BACKGROUND job: it returns `Background process started`, not output. An A/B
  sabotage loop written that way records that string as its result and proves
  nothing, and the leaked jobs then race each other and the Gradle daemon while
  you mutate the same source. Keep comparison runs in the foreground under the
  cap, one at a time, and discard any result from a run that overlapped a
  source edit.
- Never run two `flutter test` suites at once. This suite has real timing
  sensitivity, and under contention the transcription-service tests fail in
  bulk with nothing wrong in the code. A wall clock far above the usual ~50s is
  the tell; re-run alone before believing any failure from a doubled-up run.
- When a test passes here but fails for someone else, compare the INSTALLED
  dependency version against the range declared in `pyproject.toml`/
  `pubspec.yaml` before debugging the test. This machine has carried a package
  several major versions outside the declared constraint, so the local suite
  exercised code no fresh install would ever resolve.
- Grep `client/lib` for a package's symbols before adding or re-adding it to
  `pubspec.yaml`. This repo has carried a declared dependency with ZERO call
  sites, so "it is already in pubspec" is evidence about the manifest and not
  about the feature — read it as greenfield until a call site proves otherwise,
  and reuse the declared version rather than resolving a new one against the
  lock.
- Kotlin JUnit failure detail is truncated in console output. Full
  `ComparisonFailure`/`AssertionError` messages live in the generated HTML and
  XML reports under `client/build/app/` — not under `client/android/app/build/`,
  which is empty.
- Docker Desktop rewrites `~/.docker/config.json` on every startup, restoring
  `"credsStore": "desktop"`, which breaks builds from git-bash because the helper
  is not on PATH. Editing the file is undone by the next restart. Use a separate
  `DOCKER_CONFIG` directory with `credsStore` removed — and copy `contexts/` into
  it, or Docker cannot find the daemon.
- Docker Desktop's credential helper is not on the MSYS PATH, and BuildKit
  spawns its own process that ignores a PATH exported in bash — so
  `error getting credentials ... docker-credential-desktop` survives the obvious
  fix. `DOCKER_BUILDKIT=0` works around it. Don't pipe a long build through
  `tail`: the pipeline's exit code masks the build's own and the per-step
  progress is discarded, so you cannot see which layer is running. Redirect to
  a log and append `EXIT=$?`.
- NEVER read "no new image yet" as a FAILED build. A 10GB image commits its
  final layers for minutes after the last interesting log line, and the tag
  keeps pointing at the OLD id throughout — so absent side effects look
  identical to failure. Poll the process for `status` before concluding
  anything: a build declared failed here was still running and had in fact
  succeeded, and that false verdict bought a redundant 25-minute rebuild plus a
  10.5GB dangling image. Only the job's own exit/completion notification
  settles whether it failed.
- `docker compose up -d` is refused as a long-lived process by the terminal
  tool. Run it with `background=true`, then verify separately: container
  `Up (healthy)` plus the new route actually present in the live
  `/openapi.json`. A rebuilt image proves nothing until the container is
  recreated from it — confirm WHICH image it runs via `docker inspect
  tangent-server --format '{{.Image}}'` and compare against the tag's current
  id, since a tag moves while a running container keeps its old layers. Check
  the bind-mounted data survived (devices and change_log counts) rather than
  assuming the volume did its job.
- Duplicate or superseded builds leave 10.5GB dangling images behind. Report
  `docker system df` reclaimable space and remove only the orphan you created
  by id — never `docker system prune -a`, which would take the RustDesk relay
  and honcho images with it, and keep the previously-running image as the
  rollback.
- Never `docker compose up` from a second copy of this repo without overriding
  the name. `server/docker-compose.yml` pins `container_name: tangent-server`,
  so compose in a clone ADOPTS and replaces Jeff's live container and rebinds it
  to the clone's empty `./data`. Pass `-p <name>` and override `container_name`
  for any test run, and put that instruction in a worker's brief — a subagent
  hit this and took his server down.
- A read-only Docker VM filesystem (`input/output error` from `docker system df`)
  is VM disk corruption, not a build fault. Fix: stop Docker processes, run
  `wsl --shutdown` to force a disk check, restart. Restarting bounces every
  container — ask first, because Jeff runs a RustDesk relay (`hbbs`/`hbbr`) that
  drops live remote-support sessions.
- Python puts the *script's own directory* on `sys.path`, not the cwd. A script
  in `/tmp` cannot import the app package no matter what `-w` you pass to
  `docker exec`; copy it into the app directory instead.
- Bash-quoting long Python via `docker exec python -c` mangles it. Write the
  script to a file and `docker cp` it in.
- Regenerate Drift code after schema changes:
  `dart run build_runner build --delete-conflicting-outputs`, and commit the
  regenerated `.g.dart`.
- Bumping the client schema version breaks hard-coded version assertions in
  existing DB tests. Updating those assertions is expected; never weaken them.
  Whole-row snapshot assertions break too, because a new column appears in
  `SELECT *`. Scope the comparison to the columns the fixture actually had
  (`{for (final k in before.first.keys) k: row[k]}`) and ADD an assertion that
  the new column arrives at its migration default — that strengthens the test
  and survives the next column addition.
- Triage a schema-bump failure wall by SORTING the failures before editing any
  of them: an `Expected: <8> / Actual: <9>` or a column-list mismatch is the
  bump being observed correctly, while a failure about ROW CONTENT is a real
  migration bug. Read the failure text of each distinct kind and say which
  bucket it fell in. Mechanically updating every red assertion to match the new
  output is how a genuine data-loss bug gets normalised into the expected
  values.
- Adding a NON-NULLABLE column to an existing Drift table breaks every
  construction site of its data class — 141 of them here, nearly all tests —
  because the generated row class requires every non-nullable field in its
  constructor. `clientDefault` does NOT help: it feeds inserts, not the data
  class. `withDefault` alone does not either. Make new columns NULLABLE and
  read null as the pre-feature behaviour (null = not dirty, not remote); that
  turns a 141-file mechanical churn into a handful of `bool?` comparisons
  (`row.flag == true`) and a `| col.isNull()` in the queries that filter on it.
- Adding a column to an existing table is the highest-risk edit in this client:
  a wrong `onUpgrade` step bricks app launch for every existing install while
  every fresh-database test stays green. Read `references/schema-migrations.md`
  before writing one.
- A Kotlin test asserting the EXACT set of supported native channel methods is a
  deliberate review gate, not rot: adding a method fails the build until it is
  declared there, so update the expected set as part of the change. Tests that
  hard-code a COUNT of supported methods do rot — derive the count from the set.
- A default method body on an `abstract interface class` is NOT inherited
  through `implements`; every implementor, including test doubles, must declare
  the member. Adding an optional port method therefore touches each backend —
  expect `Missing concrete implementation` plus a wave of unrelated test files
  failing to compile until they all declare it.
- A compile error in a widely-imported file surfaces as failures in unrelated
  test files. Fix the compile error and re-run before investigating any test
  that "started failing" alongside it — the referenced-but-unimported symbol is
  the whole bug.
- Read the exact line an analyzer diagnostic names before editing anything.
  Lint positions point at the enclosing construct, not the statement you assume
  — a trailing-comma complaint reported inside a chained call can belong to the
  `expect(...)` wrapping it. Guessing costs a full analyze cycle per attempt and
  can raise the issue count; re-read and the fix is one edit.
- Settle a "how does this framework type actually behave?" question with a
  throwaway `*_test.dart` run through `flutter test`, then DELETE it. A
  standalone script run via `dart run` cannot load `dart:ui` and dies deep
  inside `text_painter.dart` with exhaustiveness errors that read like a broken
  SDK rather than the wrong runner. A two-minute probe beats guessing at an
  equality or const-evaluation rule — but a scratch file left behind reds the
  next analyze.
- Anchor a patch that INSERTS a class member on a complete preceding member,
  through its closing brace — never on the `class X ... {` line. These classes
  open with a constructor taking named parameters, so an insert anchored at the
  class line lands BETWEEN the constructor's parameters, which still reads as
  plausible Dart in a diff and fails later with an error naming the constructor
  rather than the edit. That failure scales: applying ONE anchor across several
  files in a loop lands correctly in the files whose shape you checked and
  mangles the rest, and each call returns success independently. When several
  files need the same member (adding a port method to every test double, say),
  read each target's class opening first, or patch them one at a time and
  analyze between. Run `analyze` immediately after any such loop, before the
  next dependent step: a batch that "all succeeded" can carry two unbuildable
  files.
- To INSERT a method before an existing one, anchor on enough of the existing
  member to reproduce it intact in `new_string`. Anchoring on just its opening
  lines and writing the new method followed by a truncated version of the old
  one DELETES the lines you left out — twice in one session a method signature
  vanished, leaving a body with no declaration. The patch reports success
  either way. Prefer anchoring on the END of the PRECEDING member (through its
  closing brace) so the insert is purely additive, and analyze immediately.
- Never `replace_all` a replacement fragment that begins with `.`. Swapping a
  method call for `.value` across a file turns every `x.foo()` into `x..value`,
  a Dart CASCADE — valid syntax, so the damage can reach runtime instead of
  failing loudly at the edit. Include the receiver on both sides of the
  replacement, or patch each site individually.
- Merge conflicts between two migration functions are almost always additive,
  not alternative: each branch appended its own migration at the same insertion
  point. Keep BOTH definitions and BOTH call sites, then prove it by running the
  server suite — never resolve by choosing a side.
- When a requirement legitimately changes, rewrite the tests that encoded the
  old one so they assert the new behavior. "Never weaken a test" forbids
  softening an assertion to get green; it does not forbid replacing a test whose
  premise no longer exists. Say which of the two is happening.
- But when a new feature reds a WALL of existing tests that all encode one
  contract, the default reading is that YOUR DESIGN is wrong, not the tests.
  Read their names before touching them — a title like "long press selects; row
  and circular control never navigate" is a safety contract someone wrote on
  purpose, usually guarding the most destructive flow on that screen. Give the
  new affordance its own entry point (a per-row menu button alongside the
  existing gesture) instead of overloading a gesture that already means
  something, and accept mild inconsistency between screens over rewriting the
  contract. Four new tests passing while twenty-eight old ones fail is the
  suite out-voting you.
- Route a new destructive action INTO the existing audited path rather than
  calling the underlying API again from the new entry point. A second deletion
  implementation has to re-derive eligibility checks, retry tickets and the
  confirmation copy, and it drifts; select the row and invoke the established
  bulk flow so there stays exactly one way for data to be destroyed.
- Disable an unavailable action and state the reason rather than hiding it. A
  control that vanishes reads as a bug; a greyed row carrying the storage
  layer's own wording ("Sync in progress") explains the app. Reuse that existing
  reason string so the menu and the list can never disagree.
- A regex assertion can start matching newly added explanatory copy elsewhere on
  the screen. Scope such a check to the specific widget (read its `.data`)
  rather than relaxing the matcher.

## Speaker diarization (server)

Optional, off by default, gated on an env flag plus a HuggingFace token in
`server/.env` (gitignored) — never commit it or quote it back in chat. For the
pyannote API shape, the label-assignment rule, and the SSE test-isolation
fixture, see `references/server-transcription-and-diarization.md`.

- Read the code that implements a behavior before documenting it or "fixing" a
  bug in it. A compose file promising persistence across rebuilds looked like a
  missing cache env var, but the service already passed an explicit download
  root under the data dir — the multi-GB model cache on disk was proof it had
  always worked. Inferring a defect from configuration and shipping a fix for
  it is the same unverified claim as any other.

## Public-release auditing

Before anything in this repo goes public, audit it as a stranger would receive
it — the working tree alone is not the artifact. Scan git HISTORY for secrets
(not just the tree), verify every README claim against the code that
implements it, and run the documented install literally in a fresh clone. Full
checklist in `references/public-release-audit.md`.

## Delegation in this project

Parallel subagents work well here, but they routinely hit iteration caps
mid-task. Expect to finish their work yourself.

- Settle cross-cutting design decisions BEFORE fanning out and repeat them in
  every child's context — workers cannot see each other. Two workers told to
  define "equivalent" types will produce incompatible constructors.
- Give each worker disjoint file ownership and say explicitly which paths belong
  to siblings.
- Front-load this project's known pitfalls (the SAF rules above) into the brief
  so workers do not rediscover them on Jeff's phone.
- Commit verified layers as you go, so a capped worker cannot strand finished
  work in an uncommitted pile.
- Read the blockers section of every worker report; they are usually honest and
  specific about what they left broken.
- When writing a handoff for another context, verify every claim against the
  TREE rather than against your own summary: re-run the status commands, grep
  each symbol you cite, and confirm any "this has no callers yet" claim with an
  actual search. The next session trusts a handoff unconditionally, so a stale
  status line or an off-by-a-few line reference misleads it for hours. Delete
  superseded status text rather than writing the new status above it — one
  document carrying two contradictory statuses is the failure shape, and the
  reader cannot tell which half is current.
- Confirm a delegated run actually PRODUCED something before reporting it. A
  background `hermes -p <profile> chat` can exit non-zero having written only an
  error line, so read the reply log and check for the expected artefact on disk.
  When a specialist cannot run, say so and ask how to proceed — never silently
  substitute a different model or quietly do the work under the specialist's
  name, because the user cannot audit authorship they were not told about.
- A worker that returns zero code can still be worth its run. Investigation
  findings — the list of call sites that will break, an unverified assumption
  worth checking — routinely save more time than the code would have.
- Verify a worker's stated assumptions before building on them. One flagged
  'unverified: does this operation require that bootstrap step?' — it did, and
  trusting the summary would have broken first-launch capture.
- A capped worker can leave the tree mid-edit and uncompilable (a parameter
  used but never declared). Run analyze before assuming its diff is inert.
- NEVER `git checkout <file>` to revert a file while workers hold uncommitted
  edits in the same worktree — it destroys their work with no stash to recover
  from. Use `git stash push -- <file>` for any temporary revert; that is also
  the correct attribution tool (stash, run, pop, compare failure counts) for
  deciding which author owns a failing test in a shared tree.
- Rebuild destroyed work from its tests rather than from memory. Behavior that
  was specified by failing-first tests is recoverable — a concrete payoff of
  the TDD requirement, and the reason to insist workers write tests first.
- Check each patch's success flag before running the dependent step. A failed
  removal paired with a successful insert silently duplicates a widget or
  block; confirm with `grep -c` on the symbol before running any gate.
- Cap hypothesis-testing that mutates shared source. After a few disproved
  theories, restore the tree to the arrangement you intend to ship, then hand
  the diagnosis to a fresh context with the dead ends listed so they are not
  retried.
- A background gate started BEFORE your fix landed reports the pre-fix tree.
  Check which revision a finished run actually covered before acting on it. The
  same trap bites any verification that CLONES the repo: a clone takes committed
  HEAD, so uncommitted fixes are invisible and the run cheerfully validates the
  broken state. Commit first, then echo and read the cloned HEAD before
  trusting a word of the result.

## UI design direction

Inspect `client/lib/main.dart` and `client/lib/theme/` before choosing a redesign
seam. Handoffs may describe an earlier stock Material theme while the live tree
already contains tokens and component themes. Extend the active system rather
than introducing a competing one. When another session advances the source
during a read-only review, inspect the intervening diff and state the reviewed
revision; a clean final status does not prove the source remained unchanged.

Once the theme is global, every screen inherits it and LOOKS right, so the
remaining redesign work is the literals that bypass it — not missing theming.
Audit by grepping `client/lib` for `Colors.` and `Color(0x` (excluding
`Colors.transparent`), never by grepping for token adoption: a screen with zero
token references can be fully themed. Treat a grep that returns zero in EVERY
file as a wrong symbol before believing it is a universal absence — confirm the
name against a file already known to use it, since a plausible class name
(`TangentTokens` for `TangentColors`) reports the whole codebase as unstyled.
A BATCH of searches that all come back empty is likewise evidence about the
search, not the tree: re-check one name you know is present through a second
mechanism (a shell `ls` or `grep`) before concluding anything is missing.

A presentation mapping duplicated across two screens drifts together and falls
out of the palette together — a status badge can carry byte-identical
`Colors.green/blue/orange/red/grey` switches in both the list and the detail
screen. Extract it to one shared function and test that function, the same
one-predicate rule the capture path follows. When each state already ships a
distinct icon, colour is reinforcement rather than the sole carrier of meaning,
which is what frees the resting states to share one dim tone.

Jeff's chosen direction is hardware-tactile dark — a recording-device chassis
rather than a Material app. The landed system ("Blackout") is: near-black
chassis `#141719`, sunken `#0E1113`, panels `#1D2124`, signal lime `#D4FF47`,
record red `#FF3B30`, text `#D9DFE3`; ~7px panels; a round physical record key;
elevation as a 1px lit top edge plus a hard `0 3px 0` drop with ZERO blur (a
blurred shadow reads as a Material card and breaks the illusion). Notebook ink
stays WHITE, not lime — handwriting must not compete with the signal colour.

Two palette rules carry product meaning, not just taste. **Red is reserved** for
capture and destruction, so the record key is red whether or not it is
recording (the icon and timer say which) and a note-mode button takes lime
instead, because writing is not a capture. **Lime means live or selected.**
Letting one colour mean both is the ambiguity the reservation exists to
prevent. Put that rule in a single tested function rather than a conditional
inside a build method.

Rejected along the way, so they need not be re-tried: mint (too cold), and
amber-on-charcoal (the look every "pro audio app" already has).

Show design options as rendered mockups (an HTML `::preview` widget with real
screen content), never as prose descriptions of colour. He refines ONE axis at a
time — picks a shape system, then swaps the palette, then tunes the accent — so
hold everything else fixed between rounds and change only the axis under
discussion.

Before any restyle, know the blast radius: 232 `find.text(...)` and 68
`find.byIcon(...)` assertions sit across the 978 green tests, versus 243
`find.byKey(...)` that survive restyling. Pure colour and shape changes cost
nothing; changed copy or icons red-wall large parts of the suite. Update those
assertions to the new strings — never weaken them to `byType`, never delete
them — and add `Key`s to new widgets so later restyling is cheaper.

Lime and pure red are near-complementary and visually vibrate when adjacent at
high saturation; pair lime with a muted brick red rather than emergency red.
Glow effects (`BoxShadow`) on many small waveform bars cost frame time in a long
list — apply them only to the active/recording waveform.

**A filled accent panel must state its own text colour.** `Text` inside a
`Card` or `Container` inherits the app's `textTheme`, NOT the container's
`onSecondaryContainer`/`onPrimary`, so a correct dark on-colour in the scheme
does nothing and light chassis text paints on lime, very nearly invisible.
Pass `color:` explicitly on every `Text` drawn on an accent fill. A scheme-level
test asserting the on-colour is dark will PASS while the screen is unreadable —
if such a test passes, the hypothesis is wrong, so print the resolved
`textTheme` colours before editing anything.

Encode palette rules as tests, not comments: assert contrast ratios against
WCAG AA, assert that ink is not the signal colour, assert elevation has zero
blur. Design decisions expressed as assertions survive the next restyle.

Comparing colours in those tests has two traps, and both fire the moment a
stock `Colors.white`/`Colors.black` is replaced by a real token. `Paint.color`
round-trips through float channels, so `expect(paint.color, someToken)` FAILS
while both sides print the identical ARGB — the assertion only ever passed
because pure white survives the round trip exactly. Compare channels instead
(`expect(paint.color.r, closeTo(expected.r, 0.001))` and siblings); `.value`
compares correctly too but is deprecated and reds `flutter analyze`. Separately,
a `const Set<Color>` does not COMPILE — `dart:ui Color` "does not have a
primitive equality" — so declare palette collections `final`.

In a list-like editor, Enter means NEXT ITEM, not a newline — a checkbox row
that grows into a paragraph is the bug. The fix is the field's INPUT
CONFIGURATION, never a key interceptor: an on-screen keyboard sends no key
events at all, so a `KeyDownEvent` handler above the field fixes only a
physical keyboard while every tablet user still watches the box grow. Declare
`keyboardType: TextInputType.text` plus an explicit `textInputAction`, act in
`onSubmitted`, and keep `maxLines: null` so a long item still WRAPS — wrapping
is `maxLines`' job, not the input type's. See
`references/soft-keyboard-and-text-input.md` for the mechanism and the proof
recipe. Insert the new item directly AFTER its source rather than appending to
the end so a list typed top-to-bottom does not scatter, and move focus into
it. Enter on an ALREADY EMPTY item ends the list, which is the only way to
stop adding. Leave prose blocks alone — they keep the multiline keyboard and
its newlines — and give the new item null coordinates so it flows beneath its
source instead of landing on top of it.

A test asserting a specific Material shade (`Colors.red.shade400`) is pinning
the wrong thing when the intent is "reads as destructive". Re-point it at the
token; that is a requirement change, not a weakened assertion.

## Device work

Jeff prefers to perform phone steps himself and have you verify the result —
offer that rather than driving blind synthetic taps. Screenshot before acting and
confirm which screen is actually foreground; a missed tap is not an app defect.
After several failed fixes for one gesture bug, hand the device back and let him
test: his finger is the only instrument that has been right every time here.

Check the foreground app before sending ANY synthetic input, via
`dumpsys activity activities | grep topResumedActivity`. Jeff uses this phone
while you work; taps sent to a foreign app land in his real conversations. On
the Fold, also confirm which display is live — `screencap -d <id>` against the
folded-away panel returns a plausible but stale image, and input goes to the
other screen entirely. Compare capture sizes across both display ids: the dark
one is a few KB, the live one hundreds.

Never uninstall or clear app data without explicit permission: it wipes the app
database, and the user must re-grant the folder permission and wait for a full
re-import afterwards. Durable files in the user-selected folder survive; anything
only in SQLite does not. Adopting pre-existing files on import requires the
storage location's legacy-restore flag to be set.

That rule covers EVERY package, not just Tangent — `pm clear` on a SYSTEM
package destroys user state that has nothing to do with the app under test.
`pm clear com.sec.android.app.launcher` wiped Jeff's entire home screen: every
folder, widget and dock arrangement, replaced by a Samsung default and
recoverable only from a Samsung Cloud or Good Lock backup he may not have. It
was run to refresh a cached launcher icon — a cosmetic goal, paid for with
unrelated user data. Before any `pm clear`, `pm uninstall`, or `rm` on a path
you did not create, name what state it destroys and get explicit permission;
if the goal is cosmetic, the answer is that no destructive command is
proportionate.

A launcher showing a STALE icon after install is a launcher cache, not a build
fault, and it needs no destructive fix. Verify the asset inside the APK first
(see `references/launcher-icons-and-app-assets.md`); once the APK is proven
correct, a reboot or simply waiting refreshes the cache on its own.

Installing force-stops the app, which interrupts a live recording. Check for an
active capture first and wait or ask, rather than silently killing one of
Jeff's recordings.

Answer "is it recording right now?" from the kernel, never from assurance and
never from the app's own UI. Jeff asks this as a trust question about hardware
in his room, so produce independent signals in the same message.
`dumpsys media.audio_flinger` lists ACTIVE record threads and is the ground
truth — empty means nothing on the device is capturing. Corroborate with
`dumpsys power | grep mWakefulness` (a Dozing device with its screen off cannot
be foreground-recording), `cmd appops get <pkg> RECORD_AUDIO` (`mode=foreground`
means the app cannot capture while backgrounded), and `pidof` to separate "not
running" from "running but idle". Do NOT read `dumpsys audio`'s recording event
log as an app-activity log: Samsung's always-on hotword service
(`com.wssyncmldm`, uid 1000) fills it with `rec update ... src:HOTWORD` lines
that predate anything you did, and reading those as the app is how a healthy
idle device gets reported as secretly recording. Date-stamp entries against
`date` on the device before attributing any of them.

Move anything binary through `exec-out` — the DB via
`adb exec-out run-as <pkg> cat <db path>`, a screenshot via
`adb exec-out screencap -p`. A plain `adb shell ... > file` mangles the bytes,
and a corrupted PNG only surfaces later as "source is not a recognized image"
rather than at the point of capture; `shell screencap -p /sdcard/x.png` followed
by `adb pull` is the other safe form. Preserve Jeff's real recordings; delete
only fixtures you created and can prove you created.

Before deleting ANY file on the device, prove it is the artefact you think it
is with two independent checks — its size or bytes, AND that no database row
references its id — then say which checks passed. A zero-byte publication
artefact is safe to remove; a same-shaped file holding real audio is not, and
the two are distinguishable only by looking. When orphaned staging files hold
real audio, back up byte-exact copies before touching anything and leave the
originals in place; a repaired copy on the host is not a substitute for the
user's own file.

Delete recordings through the app's own multi-select UI, never by deleting rows
from the pulled DB: FTS triggers and deletion-ticket tables mean a raw delete
leaves the search index inconsistent and the audio files orphaned. Screenshot
between steps to confirm only your fixtures are checked.

Read the device DB's actual `PRAGMA table_info` before writing a verification
query. Client and server schemas differ, and a guessed column name raises
mid-cell — aborting the screenshot or check that was the real proof.

A capture showing a black screen with a charge indicator is a sleeping display,
not a crashed app. Wake and unlock before concluding anything from it.

Prove the fixture holds data before diagnosing a blank screen. An empty
notebook, an unsaved edit, or a discarded change renders identically to a
rendering failure, and a plausible mechanism invented to explain it will survive
every test you write. Add a row through the UI and re-capture first; only then
is "nothing is painted" a defect.

Grep logcat for a crash by the Android header while EXCLUDING `adbd` lines.
`logcat -d | grep -c 'FATAL EXCEPTION'` matches adbd's own echo of the command
string you just sent, so it reports a crash on a healthy app every time. Filter
the captured output in the host language and cross-check `pidof` — a live pid
plus zero non-adbd matches is the real all-clear.

Prove a notification reached the shade from `dumpsys notification --noredact`,
not from the code having called `show()`. Android silently DROPS posts without
the `POST_NOTIFICATIONS` runtime grant — no error, nothing on screen — so a
correct-looking call proves nothing. The live record also carries the channel,
`importance` and `flags` a screenshot cannot show. The same rule governs the
clear path: a notification whose removal is proven only against a test double
is unverified until the live list no longer lists it. See
`references/android-notifications.md`.

Screenshot-hash comparison cannot detect movement across a uniform surface: a
blank canvas pans to identical pixels. Put visible content on screen before
using a hash diff to prove a gesture did anything, and confirm with vision that
the content MOVED rather than that some pixel changed.

A coordinate read from a menu or sheet expires when the sheet closes. Re-capture
and re-read the item positions for each tap in a multi-step menu flow; a stale
offset silently activates the neighbouring entry, and the resulting "wrong
feature ran" looks like a wiring bug.

Read tap targets from `uiautomator dump` rather than estimating them off a
screenshot: `adb -s <serial> shell uiautomator dump /sdcard/win.xml`, pull it
with `exec-out cat`, and parse each node's `bounds` to a centre point. Flutter
exposes semantic nodes, so labels and the entries of an OPEN popup menu come
back with real coordinates. A bottom-bar `PopupMenuButton` reports one wide
node spanning the whole bar — tapping that node's centre does nothing, so tap
the ICON's own coordinates to open it, then re-dump to place the items.

Tapping a text field does not guarantee it TOOK focus, and text sent to a screen
whose focus did not move is appended to whatever field is focused instead — a
secret can land on the end of the field above it, where a screenshot of the
masked box below still looks correct. Confirm focus with
`dumpsys input_method | grep mInputShown` before sending text, move between
fields with `KEYCODE_TAB` rather than a second tap, and screenshot each field
after filling it. Send the value as a SINGLE argv element
(`subprocess.run([adb, "-s", serial, "shell", "input", "text", value])`) —
routing it through a shell mangles `:` and `/` and can abort the call before
anything is typed. Clear a prefilled field with `KEYCODE_MOVE_END` followed by
enough `KEYCODE_DEL` presses to cover the longest value it could hold, and
confirm empty by screenshot, since a greyed hint reads as leftover text.

To push a modified DB back, stage it through `/data/local/tmp` and `chmod 666`
it: `run-as` cannot read `/sdcard`, and writing while the app runs fails with
permission denied — force-stop first.

Read a setting's PERSISTED value back after driving a slider; never trust the
label in a screenshot. A synthetic swipe lands on whichever discrete step its
end coordinate maps to, and a capture taken mid-gesture or against a stale frame
shows a value that was never committed — a gain believed to be unity while `2.0`
sat in the store sent every later recording down the amplified path and made an
already-fixed bug look unfixed, with the wrong subsystem blamed for an hour.
Unlike secure storage, plain preferences are readable:
`run-as <pkg> cat shared_prefs/FlutterSharedPreferences.xml`, whose double
entries carry a type prefix ahead of the digits.

Leave the device in a WORKING configuration before ending a turn. A setting
changed for an experiment (a gain, a mode, a server URL) persists long after
the session moves on, so a failed experiment silently disables the app between
sessions and Jeff discovers it before you do. Revert the experimental value, or
say plainly in the same message that the device is parked in a broken state and
exactly which setting to change back.

Published user files live in `/sdcard/Documents/Tangent` as `<uuid>.opus` plus
`<uuid>.meta.json`, with `Tangent Notebooks/` and `Tangent Text Notes/`
children — NOT under the app-private directory, where `run-as ... find` returns
nothing and reads as "the recording was never saved". Compare the directory
listing by mtime before and after a capture test, and take the listing rather
than a set-difference snapshot captured after the save has already landed.

`shared_prefs/FlutterSecureStorage.xml` is Keystore-encrypted: `run-as` can
read the key NAMES but never the values. It is still the cheapest pairing
check — a device that never completed setup has no such file at all, which
distinguishes "never paired" from "paired with a credential I cannot read".

A server that stores only a HASH of its API token has not lost the token to
you: hash a recovered candidate the way the server does, compare against the
stored digest, then confirm with one authenticated request before typing it
anywhere. That is the difference between entering a guess and knowing. Check
whether the setup endpoint will REISSUE before risking the live value — when it
refuses by design, burning that token also locks out every already-paired
device. Offer to enter a recovered credential over ADB rather than pasting a
long-lived secret into chat, and verify the result from the server side (an
authenticated request succeeding) plus the presence of the secure-storage keys,
rather than from a settings row that may be scrolled out of view.

For timing startup and capture latency, or chasing a startup hang that surfaces
no error, follow `references/device-latency-diagnosis.md`.

For microphone selection, Bluetooth/SCO routing, and verifying that an audio
platform call actually took effect, see `references/android-audio-routing.md`.

For stylus-vs-finger discrimination, the probe-app recipe for reading raw
platform pointer data, and measured EMR pen characteristics, see
`references/stylus-and-pen-input.md`.

For IME actions, soft-keyboard Enter behaviour, and proving a text field's
input configuration reached Android, see
`references/soft-keyboard-and-text-input.md`.

For the notification shade — `POST_NOTIFICATIONS`, reading a live notification
out of `dumpsys`, the permission-prompt ordering race that stranded a stale
notice, and the settled design of the transcription notice — see
`references/android-notifications.md`.

For generating the launcher/adaptive icon set, contrast-checking a brand colour
before adopting it, and proving a generated asset reached the APK, see
`references/launcher-icons-and-app-assets.md`.

For adding a method to the storage port and its native channel, publishing
binary content, and attaching content to a row that already exists, see
`references/storage-publication-port.md`.

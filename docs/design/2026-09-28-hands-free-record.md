# Hands-free record: `tangent://record`, Assistant App Action, 1×1 mic widget (2026-09-28)

Ships as **v1.31.0** (client-only, Android). One spine, three triggers.

Jeff: "a voice recording prompt similar to hey google where you say 'hey
Tangent' and it brings up the recording session already recording" →
chose Option A (ride Google Assistant) over an always-listening service,
plus: "build a small 1x1 recording icon widget … clicked and it
immediately starts a brain dump … the mic from the main screen with the
icon's color scheme."

## Picks (recorded)
- **H1 Instant.** A trigger starts the recording with no further tap — the
  trigger is the consent.
- **H2 Toggle.** A trigger while a recording is running STOPS it (so a
  pocket start is undone the same way).
- **H3 Lock screen.** Works from a locked phone: the app shows over the
  lock screen while recording; anything beyond stop (review, edit, lists)
  still needs the unlock.
- **H4 Mode.** Always a Brain Dump (same rule as the desktop hotkey: Text
  Note mode is voice-less, so the trigger flips to brain dump first).

## The spine — `tangent://record`
- New VIEW intent-filter on MainActivity: scheme `tangent`, host `record`
  (sibling of the existing `tangent://notebook/<id>` filter; internal
  scheme, no autoVerify).
- Kotlin: extend the existing launch channel
  (`dev.tangent.tangent/launch`, `WidgetLaunchIntents.kt` /
  `MainActivity.kt`) — cold start stashes a pending `record` command
  (read-once via `takeLaunchCommand`, like `takeLaunchNotebook`); warm
  start (`onNewIntent`, `singleTop`) pushes `"record"` over the channel.
- Dart: `WidgetLaunch` grows a `commands` stream + `takeInitialCommand()`.
  `HomeScreen` routes a `record` command through the SAME
  `'toggle-record'` path the desktop hotkey already uses
  (`instanceCommandsProvider` listener → `_toggleRecording()`), so the
  on-screen button, the desktop hotkey, Assistant and the widget can never
  diverge. Cold start: the command is consumed once the home screen has
  mounted and the recording controller is ready — never before
  permissions/DB init; if RECORD_AUDIO is not granted, request it and
  start on grant (do not silently drop the intent).
- H3: MainActivity gets `android:showWhenLocked="true"` and
  `android:turnScreenOn="true"` ONLY for launches carrying the record
  intent (set at runtime via `setShowWhenLocked`/`setTurnScreenOn` in
  `onCreate`/`onNewIntent` when the intent matches, cleared otherwise —
  the app must not become a lock-screen bypass for normal launches).
  A keyguard-launched session shows the home screen; navigating away
  calls `KeyguardManager.requestDismissKeyguard`, so review needs the
  unlock.

## Trigger 1 — Google Assistant (App Actions)
- `res/xml/shortcuts.xml` with a `capability` for the custom intent
  `actions.intent.START_RECORDING_TANGENT` (custom intent + inline
  `queryPatterns`: "start recording in $app", "record a brain dump in
  $app", "new recording in $app", "start a recording") → fires
  `tangent://record`. Also a static shortcut "Record" (long-press the
  launcher icon) that fires the same URI — free, and it is how Assistant
  learns the action before the first voice use.
- `<meta-data android:name="android.app.shortcuts" …>` on MainActivity.
- Spoken form is "Hey Google, start recording in Tangent"; the literal
  "Hey Tangent" is not achievable without an always-on mic service
  (documented in the README's Voice section, one paragraph, with the
  side-key tip: Settings → Advanced features → Side key → Double press →
  Open app → Tangent, which launches the app; the record shortcut is
  reachable one press further).

## Trigger 2 — 1×1 home-screen mic widget
- `res/xml/widget_record_info.xml`: `targetCellWidth/Height=1`,
  `minWidth/minHeight=40dp`, `resizeMode=none`, no configure activity,
  `widgetCategory=home_screen`, description "Start a brain dump".
- Layout `widget_record.xml`: a single `ImageView`, circular red disc
  `#FF3B30` (= `TangentColors.record`, the main-screen button) with the
  white Material `mic` glyph (`ic_widget_mic.xml` vector drawable, path
  from Material Icons `mic`, fill `#FFFFFF`), 8dp inset so the disc has
  breathing room at 1×1 on Samsung launchers, `contentDescription`
  "Record a brain dump". Same disc/glyph in `values-night` (the button is
  identical in both themes).
- `RecordWidgetProvider.kt`: `onUpdate` binds a `PendingIntent.getActivity`
  for `tangent://record` (`FLAG_IMMUTABLE | FLAG_UPDATE_CURRENT`) to the
  view. No state, no config — a tap records, a second tap stops (H2).
- Manifest receiver `.widget.RecordWidgetProvider`, exported=false,
  APPWIDGET_UPDATE filter, label "Record".
- Widget preview: `previewLayout` (API 31+) = the same layout, and a
  `previewImage` PNG for older launchers, generated from the vector.

## Trigger 3 — nothing else
Quick Settings tile and side-key are out of scope for this arc (side key
is a Samsung setting, documented; tile is a follow-up if wanted).

## Tests
- Dart: `widget_launch_test.dart` — `takeInitialCommand` is read-once;
  warm `record` command reaches the `commands` stream; unknown commands
  ignored. `home_screen_test.dart` — a `record` command starts a brain
  dump with no tap (H1), flips Text Note mode first (H4), a second command
  stops it (H2), and a command arriving before the controller is ready is
  held and applied once (not dropped, not doubled).
- Kotlin (`app/src/test`, the existing 100-test suite): intent → command
  mapping for cold/warm paths; the record intent sets showWhenLocked and a
  plain launch does not (H3 guard); `RecordWidgetProvider` binds a
  PendingIntent whose data is exactly `tangent://record`.
- Sabotages (quote real output): (S1) widget PendingIntent points at
  `tangent://notebook` → provider test fails; (S2) cold-start command
  consumed before the controller is ready → "held and applied once" test
  fails; (S3) showWhenLocked set unconditionally → H3 guard test fails;
  (S4) command handler calls the controller directly instead of the
  `toggle-record` path → the H4 Text-Note flip test fails.

## Gates + proofs
`flutter analyze` zero; full `flutter test` green (baseline +2535 ~2);
Kotlin unit tests green (baseline 100). Device proofs on the Fold: (1)
add the 1×1 widget, tap → timer running with no further tap; tap again →
stopped, recording saved and transcribed; (2) screen locked, tap the
widget → recording over the lock screen; (3) "Hey Google, start recording
in Tangent" → same. Screenshot of the widget on the home screen next to
the app icon for the colour check.

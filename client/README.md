# Tangent client

Flutter app for Android, Linux and Windows. Records audio, keeps it on the
device, and (optionally) pairs with a [Tangent server](../server/README.md)
for transcription and multi-device sync — **Settings → Server & devices → Find my
server** discovers it on the LAN, and a 6-digit code pairs the device (see
the root README's "Connecting the app to your server").

See the [root README](../README.md) for what the app does and the full
prerequisites table.

## Build

```bash
flutter pub get
flutter run                    # attached device or emulator
flutter build apk --debug      # -> build/app/outputs/flutter-apk/app-debug.apk
```

Requires Flutter ≥ 3.47 (Dart ≥ 3.13), JDK 17 and the Android SDK. Run
`flutter doctor` to find what is missing.

The first Android build downloads Gradle, the Android Gradle Plugin and NDK.

## Tests

```bash
flutter analyze                # No issues found
flutter test                   # 1562 tests
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin storage layer
```

Widget tests cover the UI and storage contracts, and the Kotlin suite covers the
Android SAF publication path.

Verify gesture, storage and recording changes on physical hardware; widget tests
do not reproduce Android input, microphone and Storage Access Framework behavior.

## Interface

The Instrument design has Anodized and Aluminium themes. Top-level screens use
a six-key rail: Capture, Recordings, Notebooks, To Do, Ask and Settings. Settings
contains nine category pages. Recordings, notebooks and to-dos can be pinned;
Ask source chips expose actions for their underlying item. Morning review is a
full screen and does not cap yesterday's captures.

## Layout

| Path | What lives there |
|---|---|
| `lib/screens/` | Capture, recordings, notebooks, to-dos, Ask and settings |
| `lib/services/` | Recording, persistence, import, sync, discovery, pairing |
| `lib/data/storage/` | Storage contract + SAF/filesystem backends |
| `android/app/src/main/kotlin/` | Native capture, SAF publication, audio routing |
| `test/` | Widget, unit and storage-contract tests |

# Tangent client

Flutter app for Android and Linux desktop. Records audio, keeps it on the
device, and (optionally) pairs with a [Tangent server](../server/README.md)
for transcription and multi-device sync — **Settings → Server → Find my
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

Requires Flutter ≥ 3.27 (Dart ≥ 3.6), JDK 17 and the Android SDK. Run
`flutter doctor` to find what is missing.

> The debug APK is ~196 MB because it bundles an uncompiled Dart kernel and
> native libraries for four ABIs. A `--release` build is far smaller. Debug
> builds also warn that Android x86 support is going away after Flutter 3.27 —
> that is a Flutter deprecation notice, not a Tangent problem.

The first build downloads Gradle, the Android Gradle Plugin and the NDK, so
expect several minutes and a few GB. Later builds take well under a minute.

## Tests

```bash
flutter analyze                # No issues found
flutter test                   # 1562 tests
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin storage layer
```

Widget tests cover the UI and storage contracts, and the Kotlin suite covers the
Android SAF publication path.

Gesture and storage behaviour has repeatedly passed headless tests while failing
on real hardware — synthetic taps move exactly zero pixels and synthetic drags
arrive as one giant jump, neither of which resembles a finger. Verify those
paths on a device before trusting a green suite.

## Layout

| Path | What lives there |
|---|---|
| `lib/screens/` | Home, dump detail, notebooks, settings |
| `lib/services/` | Recording, persistence, import, sync, discovery, pairing |
| `lib/data/storage/` | Storage contract + SAF/filesystem backends |
| `android/app/src/main/kotlin/` | Native capture, SAF publication, audio routing |
| `test/` | Widget, unit and storage-contract tests |

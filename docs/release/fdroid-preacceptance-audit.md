# F-Droid pre-acceptance audit

## Android toolchain

- Flutter's pinned Android defaults are compile SDK 36, target SDK 36, and NDK `28.2.13676358` (`FlutterExtension.kt`). API 35 `RenderParams` symbols therefore compile without a compatibility shim while runtime selection remains gated by `Build.VERSION.SDK_INT >= 35`.
- `android/app/build.gradle` strips `.note.gnu.build-id` from every native library emitted by `stripReleaseDebugSymbols`, checks every resulting ELF with the same NDK's `llvm-readelf`, and fails release builds unless at least one source-built `libsqlite3.so` was covered.
- `tool/audit_android_release.py` is the post-build gate for all four APKs. It verifies ABI contents, SQLite 3.50.2/source ID/FTS5 symbols, absence of build-id sections, absence of PDFium/pdfrx/wasm APK assets, SHA-256, and `CN=Tangent` signing. It reports (rather than hides) any absolute worktree path found in a `.so`: local Windows builds contain the expected Flutter AOT URI in `libapp.so`; CI/F-Droid reproducibility still depends on the release workflow's exact `/home/vagrant/build/dev.tangent.tangent` build root.

## Runtime-permission timing

No startup or first-run permission request exists, so no permission code was moved.

- `android/app/src/main/AndroidManifest.xml` declares `RECORD_AUDIO` and `BLUETOOTH_CONNECT`; declarations do not display runtime prompts.
- `lib/services/recording_service.dart` calls `recorder.hasPermission()` only from `start`, immediately after a user-initiated recording action. The `record` plugin owns the microphone prompt.
- `lib/services/recording_service.dart` calls `_autoRoute(interactive: true)` only from that same `start` path. `lib/services/bluetooth_permission.dart` calls `Permission.bluetoothConnect.request()` only when `interactive` is true.
- Foreground route warming uses `_autoRoute(interactive: false)`. That path reads permission status but cannot request it, so resume/startup cannot display a Bluetooth dialog.
- Existing recording-service tests cover interactive record-tap routing versus non-interactive warm routing and denied-permission fallback.

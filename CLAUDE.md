# Tangent — agent working rules

Read **`docs/HANDOVER.md`** first. Then **`docs/ENGINEERING-NOTES.md`**,
which is 98 KB of rules each paid for with a real failure.

## What this is

Self-hosted voice recorder: `client/` is Flutter + Kotlin Android, `server/`
is FastAPI + faster-whisper in Docker. Two physical devices hold **real user
audio that is not backed up elsewhere**.

## Never

- `pm clear`, uninstall, or delete app data. Always `adb install -r` over the top.
- Install or force-stop while a recording is active. Check first:
  `adb -s <serial> shell dumpsys activity services dev.tangent.tangent | grep -ci RecordingService` → must be `0`.
- Pipe builds or tests through `tail` — the exit code becomes tail's and the
  error text is lost. Use `cmd > log 2>&1; echo EXIT=$?` then grep the log.
- Trust Gradle's `BUILD SUCCESSFUL` as proof tests ran — parse the XML under
  `client/build/app/test-results/`.
- Run two `flutter test` invocations at once.
- `adb shell run-as ... cat` a database; it corrupts binary. Use `exec-out`.

## Verification standard

1. Write the test first and **watch it fail for the expected reason**.
2. **Sabotage** the code under test to prove the test guards it; restore and
   grep `SABOTAGE` to zero.
3. Unit tests are **not** hardware acceptance. A feature is done when it has
   run on a physical device with screenshot and DB/file evidence.
4. Integration seams are the dominant bug class here — five of six sync
   defects passed their own unit tests while doing nothing at runtime. Prove
   the caller reaches the callee.

## Environment

Windows 11, git-bash/MSYS, **CRLF** sources. Pass `C:/...` forward-slash
paths to native tools (no MSYS translation). Scratch in `$LOCALAPPDATA/Temp`.
Complex backslash one-liners break — write a `.py` file instead.

```
adb      C:/Users/Jeff/AppData/Local/Android/Sdk/platform-tools/adb.exe
flutter  C:/Users/Jeff/AppData/Local/flutter/bin/flutter.bat
devices  <tab-s10fe-serial> (tablet SM-X520) · <fold-serial> (Z Fold SM-F971U1)
server   http://localhost:8765 · tailscale <server-tailscale-ip>:8765
```

## Working style

Direct answers and exact commands. Report blockers honestly rather than
inventing results. Never claim something works without having observed it.

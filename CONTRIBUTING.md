# Contributing to Tangent

Thanks for taking a look. Tangent is a working app, not a design doc — the
client runs on Android and Linux, and the server is a self-hosted FastAPI +
faster-whisper service.

## Quick start

```bash
git clone https://github.com/GyratingSeaCow/tangent.git
cd tangent

# Server (needs Docker, or Python >= 3.11)
cd server
docker compose up -d          # published on host port 8765
# ...or from source:
uv sync --all-extras
uv run pytest                 # 125 passed, 1 skipped

# Client (needs Flutter >= 3.27, JDK 17, Android SDK)
cd ../client
flutter pub get
flutter test                  # 978 tests
flutter analyze               # No issues found
flutter build apk --debug
```

`flutter doctor` will tell you what is missing for the client build. See
[`README.md`](./README.md) for the full prerequisites table.

## Before you open a pull request

Run the gates. All three must be clean:

```bash
cd client && flutter analyze && flutter test
cd ../server && uv run pytest
cd ../client/android && ./gradlew :app:testDebugUnitTest
```

Tangent is built test-first. New behaviour needs a test that fails before your
change and passes after it — a test that has never failed proves nothing.

Gesture and storage code in particular has a history of passing headless tests
while breaking on a real phone, so anything touching those paths should be
verified on a device before it lands.

## Where to start

| Area | Skills | Where |
|---|---|---|
| Flutter client (Android/Linux) | Dart, Flutter, mobile UX | `client/lib/` |
| Python server (FastAPI + Whisper) | Python, async, audio | `server/app/` |
| Android storage/SAF internals | Kotlin, Android framework | `client/android/` |
| Server packaging | Docker, Compose | `server/Dockerfile` |
| Documentation & UX writing | Clear English, ADHD empathy | `docs/`, `README.md` |

## How to file an issue

GitHub Issues is the right place for bugs and feature ideas. For a bug, include
your device/OS, whether the server is involved, and what you expected instead.

## Code of conduct

Be kind. Assume good faith. Many contributors will have ADHD themselves — they
may have inconsistent commit schedules, miss meetings, or send rambling
messages. That's fine. Treat them the way you'd want to be treated.

## License

By contributing, you agree your contributions will be licensed under
[AGPL-3.0](./LICENSE).

# Contributing to Tangent

The client runs on Android, Linux and Windows. The server is FastAPI, SQLite
and faster-whisper.

## Quick start

```bash
git clone https://github.com/GyratingSeaCow/tangent.git
cd tangent

# Server (needs Docker, or Python >= 3.11)
cd server
docker compose up -d          # published on host port 8765
# ...or from source:
uv sync --all-extras
uv run pytest                 # 162 passed, 3 skipped

# Client (needs Flutter >= 3.47, JDK 17, Android SDK)
cd ../client
flutter pub get
flutter test                  # 1320 tests
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

New behaviour needs a test that fails before the change and passes after it.

Gesture and storage code in particular has a history of passing headless tests
while breaking on a real phone, so anything touching those paths should be
verified on a device before it lands.

## Where to start

| Area | Skills | Where |
|---|---|---|
| Flutter client (Android/Linux/Windows) | Dart, Flutter, mobile and desktop UX | `client/lib/` |
| Python server (FastAPI + Whisper) | Python, async, audio | `server/app/` |
| Android storage/SAF internals | Kotlin, Android framework | `client/android/` |
| Server packaging | Docker, Compose | `server/Dockerfile` |
| Documentation & UX writing | Clear English, ADHD empathy | `docs/`, `README.md` |

## How to file an issue

Use GitHub Issues for bugs and feature requests. Include the device/OS, whether
the server is involved, reproduction steps, expected behavior and actual behavior.

## Code of conduct

Be respectful and assume good faith.

## License

By contributing, you agree your contributions will be licensed under
[AGPL-3.0](./LICENSE).

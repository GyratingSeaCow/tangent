# Contributing to ADH2

> ⚠️ **Project is in design phase.** No code yet. Once v1 ships, this document becomes real.

When v1 ships, contributing will work like this:

## Quick start (future)

```bash
git clone https://github.com/GyratingSeaCow/ADH2
cd ADH2
flutter pub get
cd server
uv sync   # or pip install -r requirements.txt
docker compose up
```

## What we'll need help with

| Area | Skills | Where to start |
|---|---|---|
| Flutter client (Android/Linux/Windows) | Dart, Flutter, mobile UX | `client/` (will exist) |
| Python server (FastAPI + Whisper) | Python, async, audio | `server/` (will exist) |
| On-device Whisper bindings | C++, Android NDK, JNI | `client/native/` (will exist) |
| Server packaging (Docker) | Docker, Compose | `server/Dockerfile` (will exist) |
| Documentation & UX writing | Clear English, ADHD empathy | `docs/` |

## How to file an issue

Once v1 ships, GitHub Issues will be the right place. For now, ideas go in [the brainstorming doc](./docs/superpowers/specs/) once it's written.

## Code of conduct

Be kind. Assume good faith. Many contributors will have ADHD themselves — they may have inconsistent commit schedules, miss meetings, or send rambling messages. That's fine. Treat them the way you'd want to be treated.

## License

By contributing, you agree your contributions will be licensed under [AGPL-3.0](./LICENSE).
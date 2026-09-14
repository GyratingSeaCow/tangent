# Tangent Server

FastAPI server for the Tangent voice brain-dump app. Self-hosted, single-user, AGPL-3.0.

## Quick start (Docker)

```bash
cd server
docker compose up -d
docker compose logs -f tangent-server
```

The server prints a one-time setup URL on first run. Open it in a browser to generate your API token, then paste it into the Tangent app.

On startup, the server listens on `0.0.0.0:8000`. From the Tangent app on the same LAN, point the **Server URL** setting at `http://<your-lan-ip>:8000` (for example `http://192.168.1.42:8000`).

### Where your data lives

`./data` on the host is bind-mounted to `/data` in the container. The container writes:

- `./data/tangent.sqlite` — the server's database (dumps, jobs, auth token)
- `./data/audio/<dump-id>.opus` — uploaded audio files
- `~/.cache/huggingface/hub/` — faster-whisper model cache (HuggingFace default)

These survive container restarts and image rebuilds. If you ever want to wipe everything, stop the container and `rm -rf ./data`.

### First-run setup

The first time the container boots, `docker compose logs -f` will print a block like:

```
============================================================
Tangent first-run setup
============================================================

Server will be available at http://0.0.0.0:8000

Open this URL in a browser to generate your API token:
  http://localhost:8000/v1/setup

POST with JSON body: {"display_name": "Your Name"}
Save the returned token; it will not be shown again.
============================================================
```

1. Open `http://<lan-ip>:8000/v1/setup` in a browser (or `curl` from your dev box).
2. POST `{"display_name": "Your Name"}` and copy the returned `token`.
3. In the Tangent app, open **Settings → Server** and paste the URL + token.

If you're on the same machine as the container, `http://localhost:8000` works. From the phone, use `http://<lan-ip>:8000`.

## Configuration

All config via environment variables (set in `docker-compose.yml` or override per-service):

| Variable | Default | Description |
|---|---|---|
| `TANGENT_DATA_DIR` | `/data` | SQLite DB + audio files |
| `TANGENT_LOG_LEVEL` | `info` | `debug`/`info`/`warning`/`error` |
| `TANGENT_HOST` | `0.0.0.0` | Bind host (`0.0.0.0` for LAN access) |
| `TANGENT_PORT` | `8000` | Bind port |
| `TANGENT_WHISPER_MODEL` | `large-v3` | Default model. Valid: `tiny`, `base`, `small`, `medium`, `large-v3`. |

### Changing the model

CPU-only boxes will find `large-v3` slow per clip. Drop to `small` (≈ 465 MB, fast) or `medium` (≈ 1.5 GB, balanced) by editing `docker-compose.yml` and setting `TANGENT_WHISPER_MODEL: small`, then `docker compose up -d --force-recreate`. faster-whisper downloads the model on first transcribe and caches it under `./data` so subsequent restarts are instant.

### Customising network exposure

By default `docker-compose.yml` publishes port 8000 on all interfaces. To bind only to a specific interface (e.g. a LAN-only NIC), create `docker-compose.override.yaml`:

```yaml
services:
  tangent-server:
    ports:
      - "192.168.1.42:8000:8000"
```

`docker compose` automatically merges `docker-compose.override.yaml` on top.

## Local development (without Docker)

```bash
cd server
uv sync --all-extras
uv run pytest
uv run uvicorn app.main:app --reload
```

## License

AGPL-3.0. See [`LICENSE`](../LICENSE) at repo root.

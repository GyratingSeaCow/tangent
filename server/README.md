# Tangent Server

FastAPI server for the Tangent voice brain-dump app. Self-hosted, single-user, AGPL-3.0.

## Quick start

```bash
docker compose up -d
docker compose logs -f tangent-server
```

The server prints a one-time setup URL on first run. Open it in a browser to generate your API token, then paste it into the Tangent app.

## Local development

```bash
cd server
uv sync --all-extras
uv run pytest
uv run uvicorn app.main:app --reload
```

## Configuration

All config via environment variables (see `app/config.py`):

| Variable | Default | Description |
|---|---|---|
| `TANGENT_DATA_DIR` | `./data` | Where SQLite DB and models live |
| `TANGENT_LOG_LEVEL` | `info` | Log level (debug/info/warning/error) |
| `TANGENT_HOST` | `0.0.0.0` | Bind host |
| `TANGENT_PORT` | `8000` | Bind port |
| `TANGENT_WHISPER_MODEL` | `large-v3` | Default transcription model |

## License

AGPL-3.0. See [LICENSE](../LICENSE) at repo root.
# Tangent Server

FastAPI server for the Tangent voice brain-dump app. Self-hosted, single-user, AGPL-3.0.

## Quick start (Docker)

```bash
cd server
docker compose up -d
docker compose logs -f tangent-server
```

The server prints a one-time setup URL on first run. **POST** to it to generate
your API token, then pair your devices with the app's **Find my server**
button (see [Pairing devices](#pairing-devices)) — the endpoint is POST-only,
so opening it in a browser returns `405 Method Not Allowed`.

**Ports:** the container always listens on `8000` internally, and
`docker-compose.yml` publishes it on host port **8765**. So from your own
machine use `http://localhost:8765`, and from the phone
`http://<your-lan-ip>:8765` (for example `http://192.168.1.42:8765`). Change the
left-hand number in the compose `ports:` entry if 8765 is taken.

### Where your data lives

`./data` on the host is bind-mounted to `/data` in the container. The container writes:

- `./data/tangent.db` — the server's database (dumps, jobs, auth token)
- `./data/audio/<dump-id>.opus` — uploaded audio files
- `./data/models/` — faster-whisper model cache (`download_root`, under the data dir)

These survive container restarts and image rebuilds. If you ever want to wipe everything, stop the container and `rm -rf ./data`.

### First-run setup

The first time the container boots, `docker compose logs -f` will print a block like:

```
============================================================
Tangent first-run setup
============================================================

Server will be available at http://0.0.0.0:8000

POST to this endpoint to generate your API token:
  curl -X POST http://localhost:8000/v1/setup \
    -H "Content-Type: application/json" \
    -d '{"display_name": "Tangent Server"}'

display_name is what THIS SERVER calls itself to pairing
devices - name the machine, not yourself.
Save the returned token; it will not be shown again.
============================================================
```

The URL it prints is the *container's* view (port 8000). From outside, use the
published host port **8765**:

```bash
curl -X POST http://localhost:8765/v1/setup \
  -H "Content-Type: application/json" \
  -d '{"display_name": "Tangent Server"}'
```

1. Copy the returned `token` — it is not shown again. It is the server's
   primary credential; keep it safe.
2. Connect your devices by **pairing** (next section) — you normally never
   type this token into a device.
3. If you do connect manually (VPN/Tailscale), use `http://<lan-ip>:8765`
   from the phone (not `localhost`).

## Pairing devices

Each device earns its **own** revocable token by proving it can read the
server's output — no token copying:

1. In the app: **Settings → Server → Find my server** → tap **Pair** next to
   this server. (The app discovers it via the unauthenticated
   `GET /v1/server/info/public` beacon, which exposes only name, version and
   an auth flag.)
2. The server logs a 6-digit code the moment the device asks. Read it:

   ```bash
   # Linux/macOS:
   docker compose logs tangent-server --since 2m | grep code_issued

   # Windows PowerShell:
   docker compose logs tangent-server --since 2m | Select-String code_issued
   ```

   (Run from `server/`, or add `-f path\to\server\docker-compose.yml`.)
3. Type the code into the device. It receives a token bound to its device id
   and is fully connected.

Security properties:

- The code is **never sent to the requesting device** — only to the server's
  own log (and to already-authenticated devices via `GET /v1/pair/pending`).
- Codes expire in **120 seconds**, are stored **hashed**, and a pairing dies
  after **5 wrong attempts**. Pairing requests are rate-limited per IP.
- A server restart voids all pending pairings.
- Revoke a lost device without touching anything else:

  ```bash
  curl -X DELETE http://localhost:8765/v1/devices/<device-id>/token \
    -H "Authorization: Bearer <any-valid-token>"
  ```

  The primary setup token is not revocable this way; it lives separately.

## Configuration

All config via environment variables (set in `docker-compose.yml` or override per-service):

| Variable | Default | Description |
|---|---|---|
| `TANGENT_DATA_DIR` | `/data` | SQLite DB + audio files |
| `TANGENT_LOG_LEVEL` | `info` | `debug`/`info`/`warning`/`error` |
| `TANGENT_HOST` | `0.0.0.0` | Bind host (`0.0.0.0` for LAN access) |
| `TANGENT_PORT` | `8000` | Bind port |
| `TANGENT_WHISPER_MODEL` | `large-v3` | Default model. Valid: `tiny`, `base`, `small`, `medium`, `large-v3`. |
| `TANGENT_DIARIZATION` | _(unset)_ | Set to `1` with `HF_TOKEN` to enable speaker diarization. |
| `HF_TOKEN` | _(unset)_ | HuggingFace token, required only for diarization. Put it in `server/.env` — never commit it. |

### Speaker diarization (optional)

Off by default. It needs the pyannote stack in the image *and* a HuggingFace
token with access to the gated `pyannote/speaker-diarization` models:

```bash
echo 'TANGENT_DIARIZATION=1' >> .env
echo 'HF_TOKEN=hf_your_token_here' >> .env
TANGENT_WITH_DIARIZATION=1 docker compose up -d --build
```

`.env` is gitignored. Without both variables the server transcribes normally and
simply omits speaker labels — it never invents them.

### Changing the model

CPU-only boxes will find `large-v3` slow per clip. Drop to `small` (≈ 465 MB, fast) or `medium` (≈ 1.5 GB, balanced) by editing `docker-compose.yml` and setting `TANGENT_WHISPER_MODEL: small`, then `docker compose up -d --force-recreate`. faster-whisper downloads the model on first transcribe and caches it under
`./data/models` so subsequent restarts are instant. The first transcribe with
`large-v3` pulls roughly 3 GB, so expect it to take a while.

### Customising network exposure

By default `docker-compose.yml` publishes host port 8765 on all interfaces. To
bind only to a specific interface (e.g. a LAN-only NIC), create
`docker-compose.override.yaml`:

```yaml
services:
  tangent-server:
    ports:
      - "192.168.1.42:8765:8000"
```

`docker compose` automatically merges `docker-compose.override.yaml` on top.

## Local development (without Docker)

```bash
cd server
uv sync --extra dev        # lean: just the server + test tools
uv run pytest                                             # 185 passed, 3 skipped
uv run uvicorn app.main:create_app --factory --reload     # http://127.0.0.1:8000
```

Use `--all-extras` only if you want diarization: it pulls torch, torchaudio and
pyannote (~1.3 GB).

`app.main` exposes a `create_app()` factory rather than a module-level `app`,
so the `--factory` flag is required — without it uvicorn exits with
`Error loading ASGI app. Attribute "app" not found in module "app.main"`.

Prefer plain `pip`? Use a virtualenv so you don't install into system Python:

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
pytest
```

## License

AGPL-3.0. See [`LICENSE`](../LICENSE) at repo root.

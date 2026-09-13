# Tangent v1 Implementation Plan — Server (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working FastAPI server with API token auth, dump CRUD, async transcription jobs with `large-v3`, and SSE job-completion notifications — packaged as a single `docker compose up` deployment.

**Architecture:** Single FastAPI service. SQLite for metadata. `faster-whisper` for transcription. Server-Sent Events for job notifications. No Celery — FastAPI `BackgroundTasks` is sufficient for v1's single-user load.

**Tech Stack:**
- Python 3.11+
- FastAPI + Uvicorn
- SQLite (stdlib `sqlite3`)
- faster-whisper (CTranslate2-wrapped Whisper)
- pyannote-audio (speaker diarization, v2 — not used in v1 tasks below)
- Pydantic v2 for request/response models
- pytest for tests
- python-dotenv for config
- structlog for logging
- Docker + Docker Compose for deploy

**This plan covers Phase 1: the server only.** Client (Flutter) and on-device LLM (secretary mode) are separate plans — Phase 2 and Phase 3.

---

## Global Constraints

These are project-wide requirements every task implicitly inherits. Copied verbatim from the spec.

- **License:** AGPL-3.0. Every source file starts with the SPDX header `SPDX-License-Identifier: AGPL-3.0-or-later`. Every dependency must be AGPL-compatible or permissively licensed.
- **Single-user:** Server is single-user. No multi-tenancy, no row-level auth checks, one API token.
- **Auth:** API token via `Authorization: Bearer *** (long-lived, generated at first launch via one-time setup URL).
- **Audio retention:** Audio files are deleted from server after successful transcription by default. Server stores transcripts, not audio.
- **Transport:** HTTPS only in production. Local dev uses HTTP.
- **Conventions:**
  - Python: `snake_case` for functions/variables, `PascalCase` for classes, `UPPER_SNAKE` for constants.
  - Imports: stdlib first, third-party second, local third. Alphabetical within group.
  - Line length: 100 chars max.
  - Type hints on every public function.
  - Logging via structlog, never `print()`.
- **Test framework:** pytest. Tests live next to code in `tests/` mirroring `app/` structure.
- **Commit cadence:** One task = one commit. Conventional Commits (`feat:`, `fix:`, `chore:`, `test:`, `docs:`).
- **Working directory:** All paths in this plan are relative to `server/` (e.g., `app/main.py` means `server/app/main.py`).
- **Minimum test coverage:** Every task must add or update at least one test. TDD where possible.

---

## File Structure

This plan creates the following files. Each has one responsibility.

```
server/
├── Dockerfile                    # Container image for the server
├── docker-compose.yml            # One-command deploy
├── pyproject.toml                # Python deps + project metadata
├── pytest.ini                    # pytest config
├── .gitignore                    # Python + Docker ignores (in addition to root)
├── .dockerignore                 # Slim Docker context
├── README.md                     # Server-specific docs
├── app/
│   ├── __init__.py               # Package marker, exposes version
│   ├── main.py                   # FastAPI app factory + lifespan
│   ├── config.py                 # Settings via pydantic-settings
│   ├── logging_config.py         # structlog setup
│   ├── db.py                     # SQLite connection + schema bootstrap
│   ├── models.py                 # Pydantic request/response models
│   ├── auth.py                   # API token validation dependency
│   ├── errors.py                 # Custom exceptions + handlers
│   ├── api/
│   │   ├── __init__.py
│   │   ├── setup.py              # One-time setup endpoint
│   │   ├── dumps.py              # Dump CRUD routes
│   │   ├── jobs.py               # Transcription job routes + SSE
│   │   ├── models.py             # Server-side model management
│   │   └── server_info.py        # Health + version endpoint
│   ├── services/
│   │   ├── __init__.py
│   │   ├── transcription.py      # faster-whisper wrapper
│   │   ├── job_queue.py          # In-process job queue + state
│   │   └── storage.py            # Disk path management (audio, models)
│   └── version.py                # Single-source version constant
└── tests/
    ├── __init__.py
    ├── conftest.py               # Shared fixtures (temp dirs, test client, test DB)
    ├── test_db.py
    ├── test_auth.py
    ├── test_setup.py
    ├── test_dumps.py
    ├── test_jobs.py
    └── test_transcription.py
```

**Design boundaries:**

- `app/api/` modules only handle HTTP concerns (parsing, auth check, response shaping). Business logic lives in `app/services/`.
- `app/db.py` exposes a `get_db()` dependency that yields a connection. Routes use it via FastAPI's `Depends`.
- `app/services/job_queue.py` is the only file that knows about job state. Routes ask it, never touch jobs table directly.

---

## Tasks

### Task 1: Project skeleton + pyproject.toml

**Files:**
- Create: `server/pyproject.toml`
- Create: `server/.gitignore`
- Create: `server/.dockerignore`
- Create: `server/README.md`

**Interfaces:**
- Consumes: nothing (initial setup)
- Produces: A `server/` directory with a Python project structure ready for `uv sync` or `pip install -e .`

- [ ] **Step 1: Create the server directory and pyproject.toml**

```toml
[project]
name = "tangent-server"
version = "0.1.0"
description = "Tangent v1 server: voice brain-dump storage + transcription"
requires-python = ">=3.11"
license = { text = "AGPL-3.0-or-later" }
authors = [{ name = "GyratingSeaCow", email = "gyratingseacow@users.noreply.github.com" }]

dependencies = [
    "fastapi>=0.115.0,<1",
    "uvicorn[standard]>=0.32.0,<1",
    "pydantic>=2.9.0,<3",
    "pydantic-settings>=2.6.0,<3",
    "python-multipart>=0.0.20",
    "faster-whisper>=1.1.0,<2",
    "structlog>=24.4.0,<25",
    "python-dotenv>=1.0.1,<2",
    "sse-starlette>=2.1.3,<3",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.3.0,<9",
    "pytest-asyncio>=0.24.0,<1",
    "httpx>=0.28.1,<1",
    "ruff>=0.7.0,<1",
    "mypy>=1.13.0,<2",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["app"]

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP", "B", "C4", "SIM"]
ignore = ["E501"]

[tool.mypy]
python_version = "3.11"
strict = true

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-v --strict-markers"
asyncio_mode = "auto"
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
*.egg-info/
.pytest_cache/
.mypy_cache/
.ruff_cache/
.coverage
htmlcov/

# Virtual envs
.venv/
venv/
env/

# Local data
data/
*.db
*.db-journal
*.db-wal
*.db-shm

# Audio uploads
uploads/

# Model weights (huge, downloaded at runtime)
models/*.bin
models/*.gguf

# IDE
.vscode/
.idea/

# Env files
.env
.env.local
```

- [ ] **Step 3: Create `.dockerignore`**

```
**/__pycache__
**/*.pyc
.git/
.gitignore
.venv/
venv/
tests/
*.md
.env
.env.local
data/
*.db
*.db-journal
*.db-wal
*.db-shm
uploads/
models/
*.log
.pytest_cache/
.mypy_cache/
.ruff_cache/
.coverage
htmlcov/
```

- [ ] **Step 4: Create `README.md`**

```markdown
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
```

- [ ] **Step 5: Verify file structure**

Run:
```bash
cd server && ls -la && cat pyproject.toml | head -5
```

Expected: 4 files created, pyproject.toml shows project name `tangent-server`.

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "chore(server): scaffold project with pyproject.toml and configs"
```

---

### Task 2: Version constant + config module

**Files:**
- Create: `server/app/__init__.py`
- Create: `server/app/version.py`
- Create: `server/app/config.py`
- Create: `server/tests/__init__.py`
- Create: `server/tests/conftest.py`
- Create: `server/pytest.ini`
- Create: `server/app/logging_config.py`

**Interfaces:**
- Consumes: nothing (no dependencies on other tasks)
- Produces:
  - `app.version.__version__` — string, semantic version
  - `app.config.Settings` — pydantic-settings class with all env vars
  - `app.config.get_settings()` — cached settings instance
  - `app.logging_config.configure_logging(level: str)` — sets up structlog

- [ ] **Step 1: Write the failing test for Settings**

Create `tests/test_config.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.config module."""

import pytest
from app.config import Settings


def test_settings_defaults():
    settings = Settings()
    assert settings.data_dir == "./data"
    assert settings.log_level == "info"
    assert settings.host == "0.0.0.0"
    assert settings.port == 8000
    assert settings.whisper_model == "large-v3"


def test_settings_from_env(monkeypatch, tmp_path):
    monkeypatch.setenv("TANGENT_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TANGENT_LOG_LEVEL", "debug")
    monkeypatch.setenv("TANGENT_HOST", "127.0.0.1")
    monkeypatch.setenv("TANGENT_PORT", "9000")

    settings = Settings()
    assert settings.data_dir == str(tmp_path)
    assert settings.log_level == "debug"
    assert settings.host == "127.0.0.1"
    assert settings.port == 9000


def test_settings_data_dir_created_on_init(tmp_path):
    settings = Settings(data_dir=str(tmp_path / "new_data"))
    assert settings.data_dir == str(tmp_path / "new_data")


def test_log_level_validation():
    with pytest.raises(ValueError):
        Settings(log_level="invalid")
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_config.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app'`

- [ ] **Step 3: Create `app/__init__.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tangent server application."""

from app.version import __version__

__all__ = ["__version__"]
```

- [ ] **Step 4: Create `app/version.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Single-source version constant. Bumped by release tooling."""

__version__ = "0.1.0"
```

- [ ] **Step 5: Create `app/config.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Configuration via environment variables. Uses pydantic-settings."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


VALID_LOG_LEVELS = {"debug", "info", "warning", "error", "critical"}


class Settings(BaseSettings):
    """Server settings. All overridable via TANGENT_* env vars."""

    model_config = SettingsConfigDict(
        env_prefix="TANGENT_",
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    data_dir: str = Field(default="./data", description="Where DB and models live")
    log_level: str = Field(default="info", description="structlog level")
    host: str = Field(default="0.0.0.0", description="Bind host")
    port: int = Field(default=8000, description="Bind port")
    whisper_model: str = Field(default="large-v3", description="Default Whisper model")

    @field_validator("log_level")
    @classmethod
    def _validate_log_level(cls, v: str) -> str:
        if v.lower() not in VALID_LOG_LEVELS:
            raise ValueError(f"log_level must be one of {VALID_LOG_LEVELS}, got {v!r}")
        return v.lower()

    @field_validator("data_dir")
    @classmethod
    def _expand_path(cls, v: str) -> str:
        return str(Path(v).expanduser().resolve())

    @field_validator("port")
    @classmethod
    def _validate_port(cls, v: int) -> int:
        if not (1 <= v <= 65535):
            raise ValueError(f"port must be 1-65535, got {v}")
        return v


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Cached settings instance. Re-read env on first call only."""
    return Settings()
```

- [ ] **Step 6: Create `tests/__init__.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Test package."""
```

- [ ] **Step 7: Create `tests/conftest.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Shared pytest fixtures."""

from __future__ import annotations

import os
from collections.abc import Generator
from pathlib import Path

import pytest


@pytest.fixture
def temp_data_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Generator[Path, None, None]:
    """Provide a temporary data dir, set as TANGENT_DATA_DIR."""
    data_dir = tmp_path / "tangent_data"
    data_dir.mkdir()
    monkeypatch.setenv("TANGENT_DATA_DIR", str(data_dir))
    yield data_dir


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch) -> Generator[None, None, None]:
    """Strip all TANGENT_* env vars so tests get defaults."""
    for key in list(os.environ):
        if key.startswith("TANGENT_"):
            monkeypatch.delenv(key)
    yield
```

- [ ] **Step 8: Create `pytest.ini`**

```ini
[pytest]
testpaths = tests
addopts = -v --strict-markers
asyncio_mode = auto
pythonpath = .
```

- [ ] **Step 9: Create `app/logging_config.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""structlog configuration. Single configure_logging() entry point."""

from __future__ import annotations

import logging
import sys

import structlog


def configure_logging(level: str = "info") -> None:
    """Configure structlog + stdlib logging. Call once at app startup."""
    log_level = getattr(logging, level.upper(), logging.INFO)

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=log_level,
    )

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_log_level,
            structlog.stdlib.add_logger_name,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.dev.ConsoleRenderer(colors=False),
        ],
        wrapper_class=structlog.stdlib.BoundLogger,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str | None = None) -> structlog.stdlib.BoundLogger:
    """Get a structlog logger."""
    return structlog.get_logger(name)
```

- [ ] **Step 10: Install dependencies and run tests**

Run:
```bash
cd server && uv sync --all-extras && uv run pytest tests/test_config.py -v
```

Expected: 4 tests pass.

- [ ] **Step 11: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add config, version, and logging modules"
```

---

### Task 3: Database schema + connection layer

**Files:**
- Create: `server/app/db.py`
- Create: `server/tests/test_db.py`

**Interfaces:**
- Consumes: `app.config.get_settings()`
- Produces:
  - `app.db.init_db(data_dir: str) -> None` — creates DB and runs schema
  - `app.db.get_db() -> Generator[sqlite3.Connection, None, None]` — FastAPI dependency
  - Schema: tables `dumps`, `jobs`, `events`, `auth` (per spec §13 server side)

- [ ] **Step 1: Write the failing test for schema bootstrap**

Create `tests/test_db.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.db module."""

import sqlite3
from pathlib import Path

from app.db import get_db, init_db


def test_init_db_creates_sqlite_file(temp_data_dir: Path) -> None:
    db_path = temp_data_dir / "tangent.db"
    assert not db_path.exists()

    init_db(str(temp_data_dir))

    assert db_path.exists()


def test_init_db_creates_expected_tables(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))

    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        tables = {row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()}
    finally:
        conn.close()

    assert {"dumps", "jobs", "events", "auth"}.issubset(tables)


def test_init_db_is_idempotent(temp_data_dir: Path) -> None:
    """Calling init_db twice should not fail or duplicate tables."""
    init_db(str(temp_data_dir))
    init_db(str(temp_data_dir))  # Should not raise


def test_get_db_yields_connection_with_row_factory(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))

    conn_gen = get_db()
    conn = next(conn_gen)
    try:
        conn.execute("SELECT 1").fetchone()
    finally:
        try:
            next(conn_gen)
        except StopIteration:
            pass


def test_dumps_table_has_expected_columns(temp_data_dir: Path) -> None:
    init_db(str(temp_data_dir))
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(dumps)").fetchall()}
    finally:
        conn.close()

    expected = {
        "id", "client_id", "created_at", "updated_at", "mode",
        "duration_seconds", "title", "transcript", "audio_kept",
    }
    assert expected.issubset(cols)
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_db.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.db'`

- [ ] **Step 3: Create `app/db.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""SQLite connection layer + schema bootstrap."""

from __future__ import annotations

import sqlite3
from collections.abc import Generator
from pathlib import Path

from app.logging_config import get_logger

log = get_logger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS auth (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    token_hash TEXT NOT NULL,
    display_name TEXT,
    created_at INTEGER NOT NULL,
    setup_completed_at INTEGER
);

CREATE TABLE IF NOT EXISTS dumps (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('brain_dump', 'meeting')),
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT,
    audio_kept INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_dumps_client_id ON dumps(client_id);
CREATE INDEX IF NOT EXISTS idx_dumps_created_at ON dumps(created_at DESC);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    dump_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    model TEXT NOT NULL,
    started_at INTEGER,
    completed_at INTEGER,
    result_transcript TEXT,
    error TEXT,
    FOREIGN KEY (dump_id) REFERENCES dumps(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_dump_id ON jobs(dump_id);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dump_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (dump_id) REFERENCES dumps(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_events_dump_id ON events(dump_id);
CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at DESC);
"""


def _db_path(data_dir: str) -> Path:
    return Path(data_dir) / "tangent.db"


def init_db(data_dir: str) -> None:
    """Create the SQLite DB and apply schema. Idempotent."""
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    path = _db_path(data_dir)
    is_new = not path.exists()

    conn = sqlite3.connect(path)
    try:
        conn.executescript(SCHEMA)
        conn.commit()
    finally:
        conn.close()

    if is_new:
        log.info("database.initialized", path=str(path))
    else:
        log.debug("database.schema_applied", path=str(path))


def get_db() -> Generator[sqlite3.Connection, None, None]:
    """FastAPI dependency: yield a SQLite connection with Row factory.

    Commits on successful return, rolls back on exception.
    """
    from app.config import get_settings

    settings = get_settings()
    path = _db_path(settings.data_dir)

    # Ensure schema exists (covers the case where tests or first-launch
    # haven't called init_db explicitly)
    if not path.exists():
        init_db(settings.data_dir)

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_db.py -v
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add SQLite schema + connection layer"
```

---

### Task 4: Auth — token hashing + FastAPI dependency

**Files:**
- Create: `server/app/auth.py`
- Create: `server/app/errors.py`
- Create: `server/tests/test_auth.py`

**Interfaces:**
- Consumes: `app.config.get_settings()`, `app.db.get_db()`
- Produces:
  - `app.auth.generate_token() -> str` — generates a URL-safe random token
  - `app.auth.hash_token(token: str) -> str` — SHA-256 hash of token
  - `app.auth.require_auth(...)` — FastAPI dependency that validates `Authorization: Bearer *** → 401 if missing/invalid

- [ ] **Step 1: Write the failing test for auth**

Create `tests/test_auth.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.auth module."""

import sqlite3
from pathlib import Path

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from app.auth import generate_token, hash_token, require_auth
from app.db import init_db


@pytest.fixture
def app_with_auth(temp_data_dir: Path) -> TestClient:
    """Test app with /v1/protected endpoint that uses require_auth."""
    init_db(str(temp_data_dir))

    # Pre-seed the auth table with a known token
    raw_token = "test-token-abc123"
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, created_at) VALUES (1, ?, ?)",
            (hash_token(raw_token), 1700000000),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()

    @app.get("/v1/protected")
    def protected(user=Depends(require_auth)):
        return {"user": user}

    return TestClient(app)


def test_generate_token_returns_url_safe_string():
    token = generate_token()
    assert isinstance(token, str)
    assert len(token) >= 32
    # Should be URL-safe (no + or /)
    assert "+" not in token
    assert "/" not in token


def test_hash_token_is_deterministic():
    assert hash_token("abc") == hash_token("abc")


def test_hash_token_produces_64_char_hex():
    h = hash_token("any-string")
    assert len(h) == 64
    assert all(c in "0123456789abcdef" for c in h)


def test_require_auth_succeeds_with_valid_token(app_with_auth: TestClient):
    resp = app_with_auth.get("/v1/protected", headers={"Authorization": "Bearer test-token-abc123"})
    assert resp.status_code == 200


def test_require_auth_rejects_missing_header(app_with_auth: TestClient):
    resp = app_with_auth.get("/v1/protected")
    assert resp.status_code == 401


def test_require_auth_rejects_wrong_token(app_with_auth: TestClient):
    resp = app_with_auth.get(
        "/v1/protected", headers={"Authorization": "Bearer wrong-token"}
    )
    assert resp.status_code == 401


def test_require_auth_rejects_malformed_header(app_with_auth: TestClient):
    resp = app_with_auth.get("/v1/protected", headers={"Authorization": "test-token-abc123"})
    assert resp.status_code == 401


def test_require_auth_fails_when_no_token_configured(temp_data_dir: Path):
    """Server starts but auth table is empty → all requests rejected."""
    init_db(str(temp_data_dir))

    app = FastAPI()

    @app.get("/v1/protected")
    def protected(user=Depends(require_auth)):
        return {"user": user}

    client = TestClient(app)
    resp = client.get(
        "/v1/protected", headers={"Authorization": "Bearer anything"}
    )
    assert resp.status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_auth.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.auth'`

- [ ] **Step 3: Create `app/errors.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Custom exceptions and FastAPI exception handlers."""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


class TangentError(Exception):
    """Base exception for Tangent-specific errors."""

    status_code: int = 500
    code: str = "internal_error"

    def __init__(self, message: str, *, code: str | None = None) -> None:
        super().__init__(message)
        self.message = message
        if code is not None:
            self.code = code


class NotFoundError(TangentError):
    status_code = 404
    code = "not_found"


class UnauthorizedError(TangentError):
    status_code = 401
    code = "unauthorized"


class ValidationError(TangentError):
    status_code = 422
    code = "validation_error"


class ConflictError(TangentError):
    status_code = 409
    code = "conflict"


def register_exception_handlers(app: FastAPI) -> None:
    """Register handlers that turn TangentErrors into JSON responses."""

    @app.exception_handler(TangentError)
    async def _handle_tangent_error(request: Request, exc: TangentError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": {"code": exc.code, "message": exc.message}},
        )
```

- [ ] **Step 4: Create `app/auth.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""API token generation, hashing, and FastAPI auth dependency."""

from __future__ import annotations

import hashlib
import secrets
import sqlite3
from typing import Annotated

from fastapi import Depends, Header

from app.db import get_db
from app.errors import UnauthorizedError


def generate_token() -> str:
    """Generate a URL-safe random token (32 bytes → 43 chars)."""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """SHA-256 hex digest of a token. Used for at-rest storage."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def require_auth(
    authorization: Annotated[str | None, Header()] = None,
    db: sqlite3.Connection = Depends(get_db),
) -> str:
    """Validate Authorization: Bearer <token> header.

    Returns the display_name stored alongside the token, or raises UnauthorizedError.
    """
    if not authorization:
        raise UnauthorizedError("Missing Authorization header")

    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise UnauthorizedError("Authorization header must be 'Bearer <token>'")

    token = parts[1].strip()
    if not token:
        raise UnauthorizedError("Empty bearer token")

    token_hash = hash_token(token)
    row = db.execute(
        "SELECT display_name FROM auth WHERE id = 1 AND token_hash = ?",
        (token_hash,),
    ).fetchone()

    if row is None:
        raise UnauthorizedError("Invalid token")

    return row["display_name"] or "user"
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_auth.py -v
```

Expected: 8 tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add token auth with SHA-256 hashing + FastAPI dependency"
```

---

### Task 5: Pydantic models + setup endpoint

**Files:**
- Create: `server/app/models.py`
- Create: `server/app/api/__init__.py`
- Create: `server/app/api/setup.py`
- Create: `server/tests/test_setup.py`

**Interfaces:**
- Consumes: `app.db.get_db()`, `app.errors.*`, `app.auth.*`
- Produces:
  - `app.models.SetupRequest`, `SetupResponse`, `DumpCreate`, `DumpResponse`, `DumpPatch`, `JobResponse`, `ServerInfo`
  - `app.api.setup.router` — POST `/v1/setup` for first-time setup, no auth required
  - `app.api.setup.is_setup_complete()` helper

- [ ] **Step 1: Write the failing test for setup endpoint**

Create `tests/test_setup.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for the /v1/setup endpoint."""

from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.setup import router
from app.db import init_db


@pytest.fixture
def client(temp_data_dir: Path) -> TestClient:
    init_db(str(temp_data_dir))
    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


def test_setup_returns_token_on_first_call(client: TestClient):
    resp = client.post(
        "/v1/setup",
        json={"display_name": "Jeff"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "token" in body
    assert len(body["token"]) >= 32
    assert body["display_name"] == "Jeff"
    assert "setup_completed_at" in body


def test_setup_is_idempotent_returns_same_token(client: TestClient):
    """Calling setup twice returns the same token, not a new one."""
    resp1 = client.post("/v1/setup", json={"display_name": "Jeff"})
    resp2 = client.post("/v1/setup", json={"display_name": "Jeff"})

    assert resp1.status_code == 200
    assert resp2.status_code == 200
    assert resp1.json()["token"] == resp2.json()["token"]


def test_setup_updates_display_name(client: TestClient):
    """Second call with different display_name updates it but keeps token."""
    resp1 = client.post("/v1/setup", json={"display_name": "Jeff"})
    resp2 = client.post("/v1/setup", json={"display_name": "Jeffrey"})

    assert resp1.json()["token"] == resp2.json()["token"]
    assert resp2.json()["display_name"] == "Jeffrey"


def test_setup_rejects_empty_display_name(client: TestClient):
    resp = client.post("/v1/setup", json={"display_name": ""})
    assert resp.status_code == 422


def test_setup_validates_payload(client: TestClient):
    resp = client.post("/v1/setup", json={})
    assert resp.status_code == 422
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_setup.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.api.setup'`

- [ ] **Step 3: Create `app/models.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Pydantic request/response models."""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator


DumpMode = Literal["brain_dump", "meeting"]
JobStatus = Literal["queued", "running", "completed", "failed"]


class SetupRequest(BaseModel):
    """First-time setup payload. Empty if no display name yet."""

    display_name: str = Field(min_length=1, max_length=100)

    @field_validator("display_name")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("display_name cannot be empty after stripping")
        return v


class SetupResponse(BaseModel):
    """Setup response. Token only returned on first call."""

    token: str
    display_name: str
    setup_completed_at: datetime


class DumpCreate(BaseModel):
    """Metadata for a new dump. Audio is uploaded separately via multipart."""

    id: str = Field(min_length=8, max_length=64)
    mode: DumpMode
    duration_seconds: int = Field(ge=0, le=7200)  # 0 to 2 hours
    title: str = Field(min_length=1, max_length=500)
    created_at: datetime


class DumpPatch(BaseModel):
    """Editable fields on a dump."""

    title: str | None = Field(default=None, min_length=1, max_length=500)


class DumpResponse(BaseModel):
    id: str
    mode: DumpMode
    title: str
    transcript: str | None
    duration_seconds: int
    created_at: datetime
    updated_at: datetime


class DumpListResponse(BaseModel):
    dumps: list[DumpResponse]
    total: int
    limit: int
    offset: int


class JobCreate(BaseModel):
    """Request to enqueue a transcription job."""

    model: str = Field(default="large-v3", min_length=1, max_length=50)


class JobResponse(BaseModel):
    id: str
    dump_id: str
    status: JobStatus
    model: str
    started_at: datetime | None
    completed_at: datetime | None
    result_transcript: str | None
    error: str | None


class ServerInfo(BaseModel):
    version: str
    setup_complete: bool
    default_model: str
    available_models: list[str]
    storage_used_bytes: int
    dump_count: int
```

- [ ] **Step 4: Create `app/api/__init__.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""API routers."""
```

- [ ] **Step 5: Create `app/api/setup.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""One-time setup endpoint. No auth required (gated by 'setup already complete' check)."""

from __future__ import annotations

import sqlite3
import time
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth import generate_token, hash_token
from app.db import get_db
from app.models import SetupRequest, SetupResponse

router = APIRouter()


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, tz=timezone.utc)


@router.post("/v1/setup", response_model=SetupResponse)
def post_setup(
    payload: SetupRequest,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> SetupResponse:
    """Idempotent setup. Returns existing token if already set up; updates display name."""
    row = db.execute(
        "SELECT token_hash, display_name, setup_completed_at FROM auth WHERE id = 1"
    ).fetchone()

    if row is None:
        # First-ever setup: generate token
        raw_token = generate_token()
        new_hash = hash_token(raw_token)
        now = _now_ts()
        db.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at, setup_completed_at) "
            "VALUES (1, ?, ?, ?, ?)",
            (new_hash, payload.display_name, now, now),
        )
        # We can't recover the raw token after this — return it now, the user must save it.
        return SetupResponse(
            token=raw_token,
            display_name=payload.display_name,
            setup_completed_at=_to_iso(now),
        )

    # Already set up: update display_name if changed, return a placeholder for token
    db.execute(
        "UPDATE auth SET display_name = ? WHERE id = 1",
        (payload.display_name,),
    )
    return SetupResponse(
        token="<token-issued-on-first-setup-not-shown-again>",
        display_name=payload.display_name,
        setup_completed_at=_to_iso(row["setup_completed_at"]),
    )


def is_setup_complete(db: sqlite3.Connection) -> bool:
    """True if setup has been performed (auth row exists)."""
    row = db.execute("SELECT 1 FROM auth WHERE id = 1 LIMIT 1").fetchone()
    return row is not None
```

- [ ] **Step 6: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_setup.py -v
```

Expected: 5 tests pass. **NOTE:** The second-call test asserts the same token is returned twice. Because we can't recover the original token after hashing, the second call returns a placeholder string. The test needs to verify the *placeholder behavior* matches what we documented, OR we need to redesign setup to be non-idempotent. **Update the test to match the placeholder behavior** — adjust the assertion to check `resp1.json()["token"] != "<placeholder>"` and `resp2.json()["token"] == "<placeholder>"`. This is intentional security behavior.

- [ ] **Step 7: Update test to match security behavior**

Edit `tests/test_setup.py`:

```python
def test_setup_is_idempotent_no_new_token_after_first(client: TestClient):
    """First call returns the real token. Second call returns a placeholder.
    The token cannot be recovered from the hash."""
    resp1 = client.post("/v1/setup", json={"display_name": "Jeff"})
    resp2 = client.post("/v1/setup", json={"display_name": "Jeff"})

    assert resp1.status_code == 200
    assert resp2.status_code == 200
    # First call has real token
    assert "<token-issued" not in resp1.json()["token"]
    assert len(resp1.json()["token"]) >= 32
    # Second call returns placeholder
    assert "<token-issued" in resp2.json()["token"]
```

- [ ] **Step 8: Re-run tests**

Run:
```bash
cd server && uv run pytest tests/test_setup.py -v
```

Expected: 5 tests pass.

- [ ] **Step 9: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add /v1/setup endpoint + Pydantic models"
```

---

### Task 6: Dump CRUD endpoints

**Files:**
- Create: `server/app/api/dumps.py`
- Modify: `server/tests/conftest.py` (add `authed_client` fixture)

**Interfaces:**
- Consumes: `app.db.get_db()`, `app.auth.require_auth()`, `app.models.*`
- Produces:
  - `app.api.dumps.router` mounted at `/v1/dumps`
  - Endpoints: GET (list), POST (create), GET /{id}, PATCH /{id}, DELETE /{id}

- [ ] **Step 1: Write the failing test for dump CRUD**

Create `tests/test_dumps.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/dumps endpoints."""

import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def authed_client(temp_data_dir: Path) -> TestClient:
    init_db(str(temp_data_dir))

    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(dumps_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _make_dump_payload(idx: int = 0) -> dict:
    return {
        "id": f"dump-{idx:04d}-test-uuid",
        "mode": "brain_dump",
        "duration_seconds": 60,
        "title": f"Test dump {idx}",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def test_create_dump(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    resp = client.post("/v1/dumps", json=_make_dump_payload(1), headers=_auth(token))
    assert resp.status_code == 201
    body = resp.json()
    assert body["id"] == "dump-0001-test-uuid"
    assert body["title"] == "Test dump 1"


def test_create_dump_requires_auth(authed_client: tuple[TestClient, str]):
    client, _ = authed_client
    resp = client.post("/v1/dumps", json=_make_dump_payload(1))
    assert resp.status_code == 401


def test_create_dump_is_idempotent_on_same_uuid(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    payload = _make_dump_payload(2)
    resp1 = client.post("/v1/dumps", json=payload, headers=_auth(token))
    resp2 = client.post("/v1/dumps", json=payload, headers=_auth(token))
    assert resp1.status_code == 201
    assert resp2.status_code == 201
    # Both responses should be identical (same dump, same id)


def test_list_dumps_returns_created(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    for i in range(3):
        client.post("/v1/dumps", json=_make_dump_payload(i), headers=_auth(token))

    resp = client.get("/v1/dumps", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 3
    assert len(body["dumps"]) == 3


def test_list_dumps_supports_limit_and_offset(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    for i in range(5):
        client.post("/v1/dumps", json=_make_dump_payload(i), headers=_auth(token))

    resp = client.get("/v1/dumps?limit=2&offset=1", headers=_auth(token))
    body = resp.json()
    assert len(body["dumps"]) == 2
    assert body["limit"] == 2
    assert body["offset"] == 1
    assert body["total"] == 5


def test_get_dump_by_id(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    client.post("/v1/dumps", json=_make_dump_payload(7), headers=_auth(token))

    resp = client.get("/v1/dumps/dump-0007-test-uuid", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json()["id"] == "dump-0007-test-uuid"


def test_get_unknown_dump_returns_404(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    resp = client.get("/v1/dumps/does-not-exist", headers=_auth(token))
    assert resp.status_code == 404


def test_patch_dump_updates_title(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    client.post("/v1/dumps", json=_make_dump_payload(8), headers=_auth(token))

    resp = client.patch(
        "/v1/dumps/dump-0008-test-uuid",
        json={"title": "Renamed dump"},
        headers=_auth(token),
    )
    assert resp.status_code == 200
    assert resp.json()["title"] == "Renamed dump"


def test_delete_dump_soft_deletes(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    client.post("/v1/dumps", json=_make_dump_payload(9), headers=_auth(token))

    resp = client.delete("/v1/dumps/dump-0009-test-uuid", headers=_auth(token))
    assert resp.status_code == 204

    # Subsequent GET should 404
    resp = client.get("/v1/dumps/dump-0009-test-uuid", headers=_auth(token))
    assert resp.status_code == 404


def test_list_dumps_excludes_deleted(authed_client: tuple[TestClient, str]):
    client, token = authed_client
    for i in range(3):
        client.post("/v1/dumps", json=_make_dump_payload(i), headers=_auth(token))
    client.delete("/v1/dumps/dump-0001-test-uuid", headers=_auth(token))

    resp = client.get("/v1/dumps", headers=_auth(token))
    body = resp.json()
    assert body["total"] == 2
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_dumps.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.api.dumps'`

- [ ] **Step 3: Create `app/api/dumps.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Dump CRUD endpoints. Single-user: no row-level auth checks."""

from __future__ import annotations

import sqlite3
import time
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status

from app.auth import require_auth
from app.db import get_db
from app.errors import NotFoundError
from app.models import DumpCreate, DumpListResponse, DumpPatch, DumpResponse

router = APIRouter()


def _now_ts() -> int:
    return int(time.time())


def _to_iso(ts: int | None) -> datetime | None:
    return datetime.fromtimestamp(ts, tz=timezone.utc) if ts else None


def _row_to_dump(row: sqlite3.Row) -> DumpResponse:
    return DumpResponse(
        id=row["id"],
        mode=row["mode"],
        title=row["title"],
        transcript=row["transcript"],
        duration_seconds=row["duration_seconds"],
        created_at=_to_iso(row["created_at"]),
        updated_at=_to_iso(row["updated_at"]),
    )


@router.post("/v1/dumps", response_model=DumpResponse, status_code=status.HTTP_201_CREATED)
def create_dump(
    payload: DumpCreate,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DumpResponse:
    """Create a dump. Idempotent on id (client-generated UUID)."""
    now = _now_ts()
    created_ts = int(payload.created_at.timestamp())

    # Idempotency: if exists, return as-is
    existing = db.execute(
        "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL", (payload.id,)
    ).fetchone()
    if existing:
        return _row_to_dump(existing)

    db.execute(
        """
        INSERT INTO dumps (
            id, client_id, mode, duration_seconds, title,
            created_at, updated_at, transcript, audio_kept
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0)
        """,
        (
            payload.id,
            "single-user",
            payload.mode,
            payload.duration_seconds,
            payload.title,
            created_ts,
            now,
        ),
    )
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ?", (payload.id,)
    ).fetchone()
    return _row_to_dump(row)


@router.get("/v1/dumps", response_model=DumpListResponse)
def list_dumps(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> DumpListResponse:
    """List dumps, newest first."""
    total = db.execute(
        "SELECT COUNT(*) AS c FROM dumps WHERE deleted_at IS NULL"
    ).fetchone()["c"]

    rows = db.execute(
        """
        SELECT * FROM dumps WHERE deleted_at IS NULL
        ORDER BY created_at DESC LIMIT ? OFFSET ?
        """,
        (limit, offset),
    ).fetchall()

    return DumpListResponse(
        dumps=[_row_to_dump(r) for r in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.get("/v1/dumps/{dump_id}", response_model=DumpResponse)
def get_dump(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DumpResponse:
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise NotFoundError(f"Dump {dump_id!r} not found")
    return _row_to_dump(row)


@router.patch("/v1/dumps/{dump_id}", response_model=DumpResponse)
def patch_dump(
    dump_id: str,
    payload: DumpPatch,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DumpResponse:
    row = db.execute(
        "SELECT * FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise NotFoundError(f"Dump {dump_id!r} not found")

    updates: list[str] = []
    params: list[object] = []
    if payload.title is not None:
        updates.append("title = ?")
        params.append(payload.title)
    if updates:
        updates.append("updated_at = ?")
        params.append(_now_ts())
        params.append(dump_id)
        db.execute(f"UPDATE dumps SET {', '.join(updates)} WHERE id = ?", params)

    row = db.execute(
        "SELECT * FROM dumps WHERE id = ?", (dump_id,)
    ).fetchone()
    return _row_to_dump(row)


@router.delete("/v1/dumps/{dump_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_dump(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> Response:
    row = db.execute(
        "SELECT id FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if row is None:
        raise NotFoundError(f"Dump {dump_id!r} not found")
    db.execute(
        "UPDATE dumps SET deleted_at = ? WHERE id = ?", (_now_ts(), dump_id)
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_dumps.py -v
```

Expected: 11 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add dump CRUD endpoints with idempotency"
```

---

### Task 7: Transcription service wrapper

**Files:**
- Create: `server/app/services/__init__.py`
- Create: `server/app/services/transcription.py`
- Create: `server/tests/test_transcription.py`

**Interfaces:**
- Consumes: `app.config.get_settings()`
- Produces:
  - `app.services.transcription.TranscriptionService` class
  - Methods: `load_model(model_name: str)`, `transcribe(audio_path: str, model_name: str) -> str`

- [ ] **Step 1: Write the failing test**

Create `tests/test_transcription.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for app.services.transcription. Uses a fake model to avoid loading real Whisper."""

from pathlib import Path

from app.services.transcription import TranscriptionService


class FakeWhisperModel:
    """Stand-in for faster_whisper.WhisperModel."""

    def __init__(self, model_name: str, **kwargs):
        self.model_name = model_name
        self.kwargs = kwargs

    def transcribe(self, audio_path: str, **kwargs):
        # Return a known shape matching faster-whisper's API
        return (
            [("fake segment text", 0, 1000)],  # segments iterable
            {"language": "en"},  # info dict
        )


def test_service_loads_model_lazy(monkeypatch, tmp_path):
    """First transcribe() call should load the model; second should reuse."""
    monkeypatch.setattr(
        "app.services.transcription.WhisperModel", FakeWhisperModel
    )

    service = TranscriptionService(model_name="large-v3")

    # Initially no model loaded
    assert service._model is None

    # Fake audio file
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    text1 = service.transcribe(str(audio))
    assert text1 == "fake segment text"
    assert service._model is not None

    # Second call should NOT reload
    original_model = service._model
    text2 = service.transcribe(str(audio))
    assert text2 == "fake segment text"
    assert service._model is original_model


def test_service_returns_empty_string_for_empty_segments(monkeypatch, tmp_path):
    monkeypatch.setattr(
        "app.services.transcription.WhisperModel", FakeWhisperModel
    )

    class EmptyModel(FakeWhisperModel):
        def transcribe(self, audio_path, **kwargs):
            return ([], {"language": "en"})

    monkeypatch.setattr(
        "app.services.transcription.WhisperModel", EmptyModel
    )

    service = TranscriptionService(model_name="large-v3")
    audio = tmp_path / "fake.wav"
    audio.write_bytes(b"RIFF....")

    text = service.transcribe(str(audio))
    assert text == ""
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_transcription.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.services.transcription'`

- [ ] **Step 3: Create `app/services/__init__.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Service layer. Business logic, not HTTP concerns."""
```

- [ ] **Step 4: Create `app/services/transcription.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Wraps faster-whisper. Loads model once, reuses across transcribe() calls."""

from __future__ import annotations

from typing import TYPE_CHECKING

from app.config import get_settings
from app.logging_config import get_logger

if TYPE_CHECKING:
    from faster_whisper import WhisperModel

log = get_logger(__name__)


class TranscriptionService:
    """Lazy-loads Whisper model on first use, caches it for the process lifetime."""

    def __init__(self, model_name: str | None = None) -> None:
        self._model_name = model_name or get_settings().whisper_model
        self._model: "WhisperModel | None" = None

    @property
    def model_name(self) -> str:
        return self._model_name

    def load_model(self, model_name: str | None = None) -> None:
        """Explicitly load (or reload) the model."""
        from faster_whisper import WhisperModel

        target = model_name or self._model_name
        log.info("transcription.loading_model", model=target)
        # device="auto" lets faster-whisper pick CPU/CUDA; compute_type="int8" for CPU friendliness
        self._model = WhisperModel(target, device="auto", compute_type="int8")
        self._model_name = target
        log.info("transcription.model_loaded", model=target)

    def transcribe(self, audio_path: str) -> str:
        """Transcribe an audio file to text. Returns empty string if no speech detected."""
        if self._model is None:
            self.load_model()

        log.info("transcription.start", audio=audio_path, model=self._model_name)
        segments, info = self._model.transcribe(
            audio_path,
            beam_size=5,
            vad_filter=True,
            language=None,  # auto-detect
        )
        log.info("transcription.detected_language", language=info.language)

        text_parts: list[str] = []
        for segment in segments:
            text_parts.append(segment.text.strip())

        return " ".join(p for p in text_parts if p)


# Module-level singleton
_service: TranscriptionService | None = None


def get_transcription_service() -> TranscriptionService:
    """Get the singleton TranscriptionService."""
    global _service
    if _service is None:
        _service = TranscriptionService()
    return _service


def reset_transcription_service() -> None:
    """Reset the singleton. Useful for tests and model switching."""
    global _service
    _service = None
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_transcription.py -v
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add TranscriptionService wrapping faster-whisper"
```

---

### Task 8: Job queue + transcription job endpoint

**Files:**
- Create: `server/app/services/job_queue.py`
- Create: `server/app/api/jobs.py`
- Create: `server/tests/test_jobs.py`

**Interfaces:**
- Consumes: `app.db.get_db()`, `app.services.transcription.*`, `app.errors.*`, `app.models.*`
- Produces:
  - `app.services.job_queue.JobQueue` — runs transcription jobs in-process via FastAPI `BackgroundTasks`
  - `app.api.jobs.router` mounted at `/v1/dumps/{id}/transcribe`, `/v1/jobs/{id}`, `/v1/jobs/{id}/stream`

- [ ] **Step 1: Write the failing test for jobs**

Create `tests/test_jobs.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/dumps/{id}/transcribe and /v1/jobs/{id} endpoints."""

import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.dumps import router as dumps_router
from app.api.jobs import router as jobs_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def authed_client_with_dump(temp_data_dir: Path):
    init_db(str(temp_data_dir))

    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        # Seed a dump directly (no audio, just metadata)
        conn.execute(
            """
            INSERT INTO dumps (id, client_id, mode, duration_seconds, title,
                               created_at, updated_at, audio_kept)
            VALUES ('seed-dump-1', 'single-user', 'brain_dump', 60, 'Seeded dump', ?, ?, 0)
            """,
            (int(time.time()), int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(dumps_router)
    app.include_router(jobs_router)
    return TestClient(app), token, "seed-dump-1"


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_enqueue_transcription_returns_job(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    resp = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["dump_id"] == dump_id
    assert body["model"] == "large-v3"
    assert body["status"] in ("queued", "running", "completed")


def test_enqueue_requires_auth(authed_client_with_dump):
    client, _, dump_id = authed_client_with_dump
    resp = client.post(f"/v1/dumps/{dump_id}/transcribe", json={"model": "large-v3"})
    assert resp.status_code == 401


def test_enqueue_for_unknown_dump_returns_404(authed_client_with_dump):
    client, token, _ = authed_client_with_dump
    resp = client.post(
        "/v1/dumps/does-not-exist/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    assert resp.status_code == 404


def test_get_job_by_id(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    enq = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    job_id = enq.json()["id"]

    resp = client.get(f"/v1/jobs/{job_id}", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["id"] == job_id
    assert body["dump_id"] == dump_id


def test_get_unknown_job_returns_404(authed_client_with_dump):
    client, token, _ = authed_client_with_dump
    resp = client.get("/v1/jobs/does-not-exist", headers=_auth(token))
    assert resp.status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_jobs.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.api.jobs'`

- [ ] **Step 3: Create `app/services/job_queue.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""In-process transcription job runner.

For v1 single-user: jobs run inline using FastAPI BackgroundTasks. No Celery,
no Redis. If the process crashes mid-job, the job is marked failed on next
startup. Good enough for one user on one server.
"""

from __future__ import annotations

import sqlite3
import time
import uuid

from app.logging_config import get_logger
from app.services.transcription import get_transcription_service

log = get_logger(__name__)


def _now_ts() -> int:
    return int(time.time())


def enqueue_job(
    db: sqlite3.Connection,
    dump_id: str,
    model: str,
    audio_path: str,
) -> str:
    """Create a job row in 'queued' state. Returns the job id."""
    job_id = str(uuid.uuid4())
    db.execute(
        """
        INSERT INTO jobs (id, dump_id, status, model, started_at)
        VALUES (?, ?, 'queued', ?, NULL)
        """,
        (job_id, dump_id, model),
    )
    log.info("job.queued", job_id=job_id, dump_id=dump_id, model=model)
    return job_id


def run_job_inline(job_id: str, audio_path: str) -> None:
    """Execute a job synchronously. Updates job status as it progresses.

    Intended to be called from a FastAPI BackgroundTasks hook.
    Opens its own DB connection (the request's connection is closed by then).
    """
    from app.db import get_db

    log.info("job.starting", job_id=job_id, audio=audio_path)

    # Open a fresh connection for the background work
    gen = get_db()
    db = next(gen)
    try:
        # Mark as running
        db.execute(
            "UPDATE jobs SET status = 'running', started_at = ? WHERE id = ?",
            (_now_ts(), job_id),
        )
        db.commit()

        # Look up the job's model choice
        row = db.execute("SELECT model FROM jobs WHERE id = ?", (job_id,)).fetchone()
        if row is None:
            log.error("job.disappeared", job_id=job_id)
            return
        model_name = row["model"]

        try:
            service = get_transcription_service()
            transcript = service.transcribe(audio_path)

            db.execute(
                """
                UPDATE jobs SET status = 'completed', completed_at = ?,
                                result_transcript = ?
                WHERE id = ?
                """,
                (_now_ts(), transcript, job_id),
            )
            # Also update the dump's transcript if not already set or if server transcript is better
            db.execute(
                "UPDATE dumps SET transcript = ?, updated_at = ? "
                "WHERE id = (SELECT dump_id FROM jobs WHERE id = ?)",
                (transcript, _now_ts(), job_id),
            )
            log.info("job.completed", job_id=job_id, length=len(transcript))

        except Exception as exc:
            log.exception("job.failed", job_id=job_id)
            db.execute(
                """
                UPDATE jobs SET status = 'failed', completed_at = ?, error = ?
                WHERE id = ?
                """,
                (_now_ts(), str(exc), job_id),
            )

        db.commit()
    finally:
        try:
            next(gen)
        except StopIteration:
            pass
```

- [ ] **Step 4: Create `app/api/jobs.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Transcription job endpoints: enqueue, poll, SSE stream."""

from __future__ import annotations

import asyncio
import sqlite3
import time
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, status
from sse_starlette.sse import EventSourceResponse

from app.auth import require_auth
from app.db import get_db
from app.errors import NotFoundError
from app.logging_config import get_logger
from app.models import JobCreate, JobResponse
from app.services.job_queue import enqueue_job, run_job_inline

router = APIRouter()

log = get_logger(__name__)


def _to_iso(ts: int | None) -> datetime | None:
    return datetime.fromtimestamp(ts, tz=timezone.utc) if ts else None


def _row_to_job(row: sqlite3.Row) -> JobResponse:
    return JobResponse(
        id=row["id"],
        dump_id=row["dump_id"],
        status=row["status"],
        model=row["model"],
        started_at=_to_iso(row["started_at"]),
        completed_at=_to_iso(row["completed_at"]),
        result_transcript=row["result_transcript"],
        error=row["error"],
    )


@router.post(
    "/v1/dumps/{dump_id}/transcribe",
    response_model=JobResponse,
    status_code=status.HTTP_201_CREATED,
)
def enqueue_transcription(
    dump_id: str,
    payload: JobCreate,
    background_tasks: BackgroundTasks,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> JobResponse:
    """Enqueue a transcription job for the given dump."""
    dump_row = db.execute(
        "SELECT id FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if dump_row is None:
        raise NotFoundError(f"Dump {dump_id!r} not found")

    # For v1: audio is reconstructed from a path convention.
    # Full file upload is a separate concern (out of scope for the server-only plan).
    audio_path = f"/data/audio/{dump_id}.wav"  # TODO: real path resolution

    job_id = enqueue_job(db, dump_id, payload.model, audio_path)

    # Schedule the actual work in the background
    background_tasks.add_task(run_job_inline, job_id, audio_path)

    row = db.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return _row_to_job(row)


@router.get("/v1/jobs/{job_id}", response_model=JobResponse)
def get_job(
    job_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> JobResponse:
    row = db.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    if row is None:
        raise NotFoundError(f"Job {job_id!r} not found")
    return _row_to_job(row)


@router.get("/v1/jobs/{job_id}/stream")
async def stream_job(
    job_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> EventSourceResponse:
    """SSE stream. Emits events as the job progresses: queued → running → completed/failed."""
    row = db.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    if row is None:
        raise NotFoundError(f"Job {job_id!r} not found")

    async def event_generator():
        last_status: str | None = None
        # Poll for up to 30 minutes
        for _ in range(1800):
            row = db.execute(
                "SELECT status, result_transcript, error FROM jobs WHERE id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                yield {"event": "error", "data": "job disappeared"}
                return

            status = row["status"]
            if status != last_status:
                payload = {"status": status}
                if status == "completed":
                    payload["transcript"] = row["result_transcript"]
                elif status == "failed":
                    payload["error"] = row["error"]
                yield {"event": status, "data": str(payload)}
                last_status = status

            if status in ("completed", "failed"):
                return

            await asyncio.sleep(1)

        yield {"event": "timeout", "data": "job did not complete within 30 minutes"}

    return EventSourceResponse(event_generator())
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_jobs.py -v
```

Expected: 5 tests pass. **NOTE:** The audio file doesn't actually exist in tests; the job will fail when transcription runs because the audio path is fake. That's fine — we're testing the API surface, not the actual transcription. To avoid test noise from background task errors, mark the test as accepting that the background job may fail.

Add a small refinement to the first test:

```python
def test_enqueue_transcription_returns_job(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    resp = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3"},
        headers=_auth(token),
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["dump_id"] == dump_id
    assert body["model"] == "large-v3"
    # Job is queued synchronously; status will transition in background
    assert body["status"] in ("queued", "running", "completed", "failed")
```

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add transcription job endpoints + SSE stream"
```

---

### Task 9: Server info + model management endpoints

**Files:**
- Create: `server/app/api/models.py`
- Create: `server/app/api/server_info.py`
- Create: `server/app/services/storage.py`

**Interfaces:**
- Consumes: `app.config.get_settings()`, `app.db.get_db()`, `app.auth.require_auth()`, `app.api.setup.is_setup_complete()`
- Produces:
  - `app.services.storage.get_storage_used_bytes(data_dir) -> int`
  - `app.api.server_info.router` — GET `/v1/server/info`
  - `app.api.models.router` — GET `/v1/models`, POST `/v1/models/{name}/pull`

- [ ] **Step 1: Write the failing test**

Create `tests/test_server_info.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for /v1/server/info, /v1/models, /v1/models/{name}/pull."""

import sqlite3
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.models import router as models_router
from app.api.server_info import router as info_router
from app.auth import generate_token, hash_token
from app.db import init_db


@pytest.fixture
def client(temp_data_dir: Path):
    init_db(str(temp_data_dir))

    token = generate_token()
    conn = sqlite3.connect(temp_data_dir / "tangent.db")
    try:
        conn.execute(
            "INSERT INTO auth (id, token_hash, display_name, created_at) VALUES (1, ?, ?, ?)",
            (hash_token(token), "TestUser", int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()

    app = FastAPI()
    app.include_router(info_router)
    app.include_router(models_router)
    return TestClient(app), token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_server_info_returns_version(client):
    cli, token = client
    resp = cli.get("/v1/server/info", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["version"] == "0.1.0"
    assert body["setup_complete"] is True
    assert body["default_model"] == "large-v3"
    assert isinstance(body["available_models"], list)
    assert body["dump_count"] == 0


def test_server_info_requires_auth(client):
    cli, _ = client
    resp = cli.get("/v1/server/info")
    assert resp.status_code == 401


def test_list_models_returns_supported(client):
    cli, token = client
    resp = cli.get("/v1/models", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body, list)
    assert "large-v3" in body


def test_pull_model_returns_status(client):
    cli, token = client
    resp = cli.post("/v1/models/large-v3/pull", headers=_auth(token))
    # For v1, pull is a no-op stub that returns "already_loaded" or "queued"
    assert resp.status_code == 200
    body = resp.json()
    assert "model" in body
    assert body["model"] == "large-v3"
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_server_info.py -v
```

Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Create `app/services/storage.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Disk-space and path helpers."""

from __future__ import annotations

from pathlib import Path


def get_storage_used_bytes(data_dir: str) -> int:
    """Recursively sum file sizes under data_dir. Excludes the .db file itself."""
    root = Path(data_dir)
    if not root.exists():
        return 0
    total = 0
    for path in root.rglob("*"):
        if path.is_file() and path.suffix not in {".db", ".db-journal", ".db-wal", ".db-shm"}:
            total += path.stat().st_size
    return total


SUPPORTED_MODELS = ("tiny", "base", "small", "medium", "large-v3")


def is_supported_model(name: str) -> bool:
    return name in SUPPORTED_MODELS
```

- [ ] **Step 4: Create `app/api/models.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Model management: list, pull."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.auth import require_auth
from app.errors import ValidationError
from app.services.storage import SUPPORTED_MODELS, is_supported_model

router = APIRouter()


class PullResponse(BaseModel):
    model: str
    status: str  # "already_loaded" | "queued" | "downloaded"


@router.get("/v1/models", response_model=list[str])
def list_models(
    _user: Annotated[str, Depends(require_auth)],
) -> list[str]:
    """List Whisper models this server supports."""
    return list(SUPPORTED_MODELS)


@router.post("/v1/models/{model_name}/pull", response_model=PullResponse)
def pull_model(
    model_name: str,
    _user: Annotated[str, Depends(require_auth)],
) -> PullResponse:
    """Trigger download of a model.

    v1 stub: faster-whisper downloads lazily on first transcribe(). This endpoint
    pre-warms the cache by calling load_model() in a thread.
    """
    if not is_supported_model(model_name):
        raise ValidationError(
            f"Unknown model {model_name!r}. Supported: {SUPPORTED_MODELS}"
        )

    from app.services.transcription import get_transcription_service

    service = get_transcription_service()
    if service.model_name == model_name and service._model is not None:
        return PullResponse(model=model_name, status="already_loaded")

    # Trigger download
    service.load_model(model_name)
    return PullResponse(model=model_name, status="downloaded")
```

- [ ] **Step 5: Create `app/api/server_info.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Server info endpoint."""

from __future__ import annotations

import sqlite3
from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth import require_auth
from app.config import get_settings
from app.db import get_db
from app.models import ServerInfo
from app.services.storage import SUPPORTED_MODELS, get_storage_used_bytes
from app.version import __version__

router = APIRouter()


@router.get("/v1/server/info", response_model=ServerInfo)
def get_server_info(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> ServerInfo:
    settings = get_settings()
    dump_count = db.execute(
        "SELECT COUNT(*) AS c FROM dumps WHERE deleted_at IS NULL"
    ).fetchone()["c"]

    return ServerInfo(
        version=__version__,
        setup_complete=db.execute("SELECT 1 FROM auth WHERE id = 1").fetchone() is not None,
        default_model=settings.whisper_model,
        available_models=list(SUPPORTED_MODELS),
        storage_used_bytes=get_storage_used_bytes(settings.data_dir),
        dump_count=dump_count,
    )
```

- [ ] **Step 6: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_server_info.py -v
```

Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): add server info + model management endpoints"
```

---

### Task 10: FastAPI app factory + lifespan + main entrypoint

**Files:**
- Create: `server/app/main.py`

**Interfaces:**
- Consumes: All routers, `app.config.get_settings()`, `app.db.init_db()`, `app.logging_config.configure_logging()`, `app.errors.register_exception_handlers()`
- Produces:
  - `app.main.create_app() -> FastAPI` — app factory
  - `app.main.run()` — entrypoint for `python -m app`

- [ ] **Step 1: Write the failing integration test**

Create `tests/test_main.py`:

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""Integration test: full app boots, routes are mounted, setup flow works."""

from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app


def test_app_boots_and_serves_setup(temp_data_dir: Path):
    app = create_app()
    client = TestClient(app)

    # GET /v1/server/info without auth → 401
    resp = client.get("/v1/server/info")
    assert resp.status_code == 401

    # POST /v1/setup → 200 with token
    resp = client.post("/v1/setup", json={"display_name": "Jeff"})
    assert resp.status_code == 200
    token = resp.json()["token"]
    assert len(token) >= 32

    # GET /v1/server/info with auth → 200
    resp = client.get("/v1/server/info", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["setup_complete"] is True


def test_app_lifespan_creates_data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("TANGENT_DATA_DIR", str(tmp_path / "fresh_data"))
    # Clear cached settings from previous tests
    from app.config import get_settings
    get_settings.cache_clear()

    app = create_app()
    with TestClient(app):
        pass  # Lifespan runs on enter, cleanup on exit

    assert (tmp_path / "fresh_data").exists()
    assert (tmp_path / "fresh_data" / "tangent.db").exists()
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd server && uv run pytest tests/test_main.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'app.main'`

- [ ] **Step 3: Create `app/main.py`**

```python
SPDX-License-Identifier: AGPL-3.0-or-later
"""FastAPI app factory. Lifespan handles DB init + logging setup."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.dumps import router as dumps_router
from app.api.jobs import router as jobs_router
from app.api.models import router as models_router
from app.api.server_info import router as info_router
from app.api.setup import router as setup_router
from app.config import get_settings
from app.db import init_db
from app.errors import register_exception_handlers
from app.logging_config import configure_logging, get_logger
from app.version import __version__

log = get_logger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Startup: configure logging, init DB. Shutdown: log exit."""
    settings = get_settings()
    configure_logging(settings.log_level)
    log.info("server.starting", version=__version__, data_dir=settings.data_dir)
    init_db(settings.data_dir)
    yield
    log.info("server.stopping")


def create_app() -> FastAPI:
    """Build the FastAPI app. Routers mounted under /v1."""
    app = FastAPI(
        title="Tangent Server",
        version=__version__,
        description="Self-hosted voice brain-dump transcription (AGPL-3.0)",
        lifespan=lifespan,
    )

    # Routers (order doesn't matter, but keep setup first for clarity)
    app.include_router(setup_router)  # /v1/setup (no auth)
    app.include_router(dumps_router)  # /v1/dumps
    app.include_router(jobs_router)   # /v1/dumps/{id}/transcribe, /v1/jobs
    app.include_router(models_router)  # /v1/models
    app.include_router(info_router)   # /v1/server/info

    register_exception_handlers(app)
    return app


def run() -> None:
    """Entrypoint for `python -m app`."""
    import uvicorn

    settings = get_settings()
    uvicorn.run(
        "app.main:create_app",
        factory=True,
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
    )


if __name__ == "__main__":
    run()
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd server && uv run pytest tests/test_main.py -v
```

Expected: 2 tests pass.

- [ ] **Step 5: Run the full test suite**

Run:
```bash
cd server && uv run pytest -v
```

Expected: All tests pass (roughly 30+ tests across all files).

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): wire up FastAPI app factory with all routers"
```

---

### Task 11: Dockerfile + docker-compose

**Files:**
- Create: `server/Dockerfile`
- Create: `server/docker-compose.yml`

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
# SPDX-License-Identifier: AGPL-3.0-or-later
# Tangent server container image.
FROM python:3.11-slim AS base

# System deps for faster-whisper (ffmpeg) + audio handling
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /app

# Install deps first (cache layer)
COPY pyproject.toml ./
RUN uv pip install --system --no-cache .

# Copy app code
COPY app ./app

# Data directory (mounted as volume in compose)
RUN mkdir -p /data
ENV TANGENT_DATA_DIR=/data
ENV TANGENT_HOST=0.0.0.0
ENV TANGENT_PORT=8000

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/v1/server/info || exit 1

# Run server (skip first-time setup URL print for now; will add in next iteration)
CMD ["python", "-m", "app"]
```

- [ ] **Step 2: Create `docker-compose.yml`**

```yaml
# SPDX-License-Identifier: AGPL-3.0-or-later
services:
  tangent-server:
    build: .
    container_name: tangent-server
    ports:
      - "8000:8000"
    volumes:
      - tangent-data:/data
    environment:
      - TANGENT_DATA_DIR=/data
      - TANGENT_LOG_LEVEL=info
      - TANGENT_WHISPER_MODEL=large-v3
    restart: unless-stopped

volumes:
  tangent-data:
    name: tangent-data
```

- [ ] **Step 3: Verify the Dockerfile parses**

Run:
```bash
cd server && docker build --target base -t tangent-server:test . 2>&1 | tail -10
```

Expected: Build succeeds or fails on missing `app/` import (which we haven't copied yet — that's OK, just checking syntax).

If you get "app not found" errors, that's expected. The real test is in Task 12.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "chore(server): add Dockerfile and docker-compose"
```

---

### Task 12: First-run setup URL print + manual smoke test

**Files:**
- Modify: `server/app/main.py` (add first-run detection that prints setup URL)

- [ ] **Step 1: Add first-run detection**

Edit `server/app/main.py`. Replace the `lifespan` function:

```python
@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Startup: configure logging, init DB, print setup URL on first run.
    Shutdown: log exit."""
    settings = get_settings()
    configure_logging(settings.log_level)
    log.info("server.starting", version=__version__, data_dir=settings.data_dir)
    init_db(settings.data_dir)

    # Print setup URL on first run
    from app.db import get_db
    from app.api.setup import is_setup_complete

    gen = get_db()
    db = next(gen)
    try:
        if not is_setup_complete(db):
            print("")
            print("=" * 60)
            print("Tangent first-run setup")
            print("=" * 60)
            print("")
            print(f"Server will be available at http://{settings.host}:{settings.port}")
            print("")
            print("Open this URL in a browser to generate your API token:")
            print(f"  http://localhost:{settings.port}/v1/setup")
            print("")
            print("POST with JSON body: {\"display_name\": \"Your Name\"}")
            print("Save the returned token; it will not be shown again.")
            print("=" * 60)
            print("")
        else:
            log.info("server.setup_complete")
    finally:
        try:
            next(gen)
        except StopIteration:
            pass

    yield
    log.info("server.stopping")
```

- [ ] **Step 2: Manual smoke test — local uvicorn**

Run:
```bash
cd server && uv run uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8765 2>&1
```

Expected: Server starts, prints the setup URL banner to stdout. (Run in another terminal or background.)

Then in another shell:
```bash
curl -s http://127.0.0.1:8765/v1/server/info
# Should return 401 (auth required)

curl -s -X POST http://127.0.0.1:8765/v1/setup -H "Content-Type: application/json" -d '{"display_name":"Test"}'
# Should return token
```

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "feat(server): print first-run setup URL banner"
```

---

### Task 13: Final test sweep + coverage check

**Files:** (no new files; verify existing)

- [ ] **Step 1: Run full test suite with coverage**

Run:
```bash
cd server && uv run pytest --cov=app --cov-report=term-missing 2>&1 | tail -50
```

Expected: All tests pass, coverage > 70% (some modules like transcription may be lower because we mock the real WhisperModel).

- [ ] **Step 2: Run linter**

Run:
```bash
cd server && uv run ruff check app/ tests/ 2>&1 | tail -20
```

Expected: Zero errors.

- [ ] **Step 3: Run type checker**

Run:
```bash
cd server && uv run mypy app/ 2>&1 | tail -20
```

Expected: Zero errors.

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
cd ~/Documents/ADH2
git add server/
git commit -m "chore(server): final lint/type/test cleanup before handoff"
```

---

## What's NOT in this plan (deferred to next phase)

This plan covers **only the server** (Phase 1). The following are explicitly out of scope and will be separate plans:

| Not in this plan | Where it goes |
|---|---|
| Flutter client UI (recording screen, dumps list, settings) | Phase 2 — separate plan, owned by `zoe` |
| On-device Whisper small + bindings for Android/Linux/Windows | Phase 2 — included in the Flutter plan |
| On-device LLM (Gemma 2B / Phi-3-mini) for secretary mode | Phase 3 — research-heavy, owned by `sol` |
| Audio file upload endpoint (multipart, large file handling) | Server Phase 1.5 — small follow-up |
| Real setup-token-recovery flow (currently placeholder on repeat calls) | Server Phase 1.5 |
| pyannote-audio speaker diarization | Server Phase 2 — opt-in enhancement |
| TLS termination, reverse proxy config | Server Phase 1.5 — operational docs |

---

## Self-Review (performed by author)

### Spec coverage

| Spec section | Covered by task |
|---|---|
| §4 Architecture (server) | Tasks 2, 3, 7, 11 |
| §5 Authentication (setup URL + token) | Tasks 4, 5, 12 |
| §12 REST API surface (all 11 endpoints) | Tasks 5 (setup), 6 (dumps), 8 (jobs), 9 (models + info) |
| §13 Data model (server side) | Task 3 |
| §14 Docker server setup | Tasks 11, 12 |
| §16 v1 success criteria #3 (server mode works) | Tasks 5–12 (validated end-to-end in Task 12) |
| §16 success criteria #7 (AGPL compliance) | Every file has SPDX header (Tasks 1–10) |

### Placeholder scan

- `grep -nE "TBD|TODO|FIXME|XXX"` — should return zero matches (one intentional TODO in Task 8 for real audio path resolution; will be addressed in Phase 1.5).

### Type consistency

- All routes use `Annotated[X, Depends(get_db)]` style (PEP 593) — consistent.
- All response models use the same Pydantic classes from `app.models` — consistent.
- All time functions use `_now_ts()` returning Unix int — consistent.

### Risks for reviewer

1. **Audio path convention** (Task 8): I use `f"/data/audio/{dump_id}.wav"` as a placeholder. Real audio upload + storage will be Phase 1.5. **For v1 server demo, this means transcription will fail** because the audio file won't exist. The plan should be honest about this — call it out in the success criteria: "server can enqueue jobs and complete them when audio files are uploaded; full audio upload flow is Phase 1.5."
2. **Single FastAPI process** for background tasks: fine for single-user, but if you restart the server mid-job, the job is lost. v1 acceptable trade-off. **Document in production-readiness note.**
3. **No HTTPS in local dev**: the spec mandates HTTPS in production. Production deployment is operational, not in this plan. **Document in deploy docs (Task 14 — see below).**

---

## Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-13-v1-brain-dump.md`.**

**Estimated effort:** 13 tasks × ~30 minutes each = ~6–8 hours of focused implementation. Ted (server profile) can ship this in 2–3 days.

**Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for catching mistakes early.

**2. Inline Execution** — Execute tasks in this session, batch execution with checkpoints.

**Which approach?**
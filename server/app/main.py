# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-License-Identifier: AGPL-3.0-or-later
"""FastAPI app factory. Lifespan handles DB init + logging setup."""

from __future__ import annotations

import contextlib
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.dumps import router as dumps_router
from app.api.jobs import router as jobs_router
from app.api.models import router as models_router
from app.api.server_info import router as info_router
from app.api.setup import router as setup_router
from app.api.sync import router as sync_router
from app.config import get_settings
from app.db import init_db
from app.errors import register_exception_handlers
from app.logging_config import configure_logging, get_logger
from app.services.job_queue import fail_interrupted_jobs
from app.version import __version__

log = get_logger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Startup: configure logging, init DB, print setup URL on first run.
    Shutdown: log exit."""
    settings = get_settings()
    configure_logging(settings.log_level)
    log.info("server.starting", version=__version__, data_dir=settings.data_dir)
    init_db(settings.data_dir)

    # Print setup URL on first run
    from app.api.setup import is_setup_complete
    from app.db import get_db

    gen = get_db()
    db = next(gen)
    try:
        fail_interrupted_jobs(db)
        if not is_setup_complete(db):
            print("")
            print("=" * 60)
            print("Tangent first-run setup")
            print("=" * 60)
            print("")
            print(f"Server is listening on http://{settings.host}:{settings.port}")
            print("")
            print("POST to this endpoint to generate your API token:")
            print(f"  curl -X POST http://localhost:{settings.port}/v1/setup \\")
            print('    -H "Content-Type: application/json" \\')
            print('    -d \'{"display_name": "Your Name"}\'')
            print("")
            print("The endpoint is POST-only — opening it in a browser returns 405.")
            print("Running in Docker? Use the HOST port published in")
            print("docker-compose.yml (8765 by default), not the port above.")
            print("Save the returned token; it will not be shown again.")
            print("=" * 60)
            print("")
        else:
            log.info("server.setup_complete")
    finally:
        with contextlib.suppress(StopIteration):
            next(gen)

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
    app.include_router(sync_router)   # /v1/devices, /v1/sync/pull, /v1/sync/push

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

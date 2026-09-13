# SPDX-License-Identifier: AGPL-3.0-or-later
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
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Server info endpoint."""

from __future__ import annotations

import sqlite3
from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth import require_auth
from app.config import get_settings
from app.db import get_db
from app.models import PublicServerInfo, ServerInfo
from app.services.storage import SUPPORTED_MODELS, get_storage_used_bytes
from app.version import __version__

router = APIRouter()


@router.get("/v1/server/info/public", response_model=PublicServerInfo)
def get_public_server_info(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
) -> PublicServerInfo:
    """Unauthenticated discovery form.

    A client sweeping its subnet needs a cheap way to tell "Tangent server"
    from "some other web thing on the same port". This answers that and
    NOTHING else: name, version, whether auth is required. Every private
    field stays on the authenticated endpoint above.
    """
    row = db.execute("SELECT display_name FROM auth WHERE id = 1").fetchone()
    return PublicServerInfo(
        # Setup names the server; before setup it introduces itself
        # generically and requires_auth=False tells the client to run setup.
        name=(row["display_name"] if row else None) or "Tangent",
        version=__version__,
        requires_auth=row is not None,
    )


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

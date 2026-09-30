# SPDX-License-Identifier: AGPL-3.0-or-later
"""Auto-file settings endpoints: the server-side toggle gating the
post-transcription auto-file trigger. Mirrors /v1/summaries/settings in
shape — the toggle gates a SERVER trigger, so it lives server-side and a
device flipping it changes behavior for every device."""

from __future__ import annotations

import sqlite3
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.services import auto_file

router = APIRouter()

log = get_logger(__name__)


class AutoFileSettingsResponse(BaseModel):
    #: The server-side auto-file toggle (trigger gate). Defaults ON.
    enabled: bool


class AutoFileSettingsUpdate(BaseModel):
    enabled: bool | None = None


@router.get("/v1/auto-file/settings", response_model=AutoFileSettingsResponse)
def get_auto_file_settings(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> AutoFileSettingsResponse:
    """The auto-file toggle, for the client's Settings section."""
    return AutoFileSettingsResponse(enabled=auto_file.auto_file_enabled(db))


@router.post("/v1/auto-file/settings", response_model=AutoFileSettingsResponse)
def update_auto_file_settings(
    payload: AutoFileSettingsUpdate,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> AutoFileSettingsResponse:
    """Persist the auto-file toggle server-side.

    The toggle gates a SERVER trigger (job_queue's post-transcription
    hook), so it lives in the server's settings table — a device toggling
    it changes behavior for every device (summaries-toggle precedent).
    """
    if "enabled" in payload.model_fields_set and payload.enabled is not None:
        auto_file.set_auto_file_enabled(db, payload.enabled)
        log.info("auto_file.toggle_set", enabled=payload.enabled)
    return AutoFileSettingsResponse(enabled=auto_file.auto_file_enabled(db))

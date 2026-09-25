# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whisper model selection endpoints: inventory, select, install, delete.

Mirrors /v1/summaries/* in shape (the AI-summaries install wizard) because
the client reuses that wizard's contract: a 202 install, a polled
``{phase, percent, detail}`` progress, and 409 as "attach", never an error.
"""

from __future__ import annotations

import sqlite3
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.services import whisper_models
from app.services.storage import (
    is_supported_model,
    resolve_active_model,
    set_active_model,
)
from app.services.transcription import reset_transcription_service

router = APIRouter()

log = get_logger(__name__)


class ModelInfo(BaseModel):
    """One row of the client's picker."""

    name: str
    installed: bool
    #: Measured bytes on disk; 0 when not installed.
    size_bytes_on_disk: int
    #: APPROXIMATE, for the confirm copy ("~3.1 GB") — never asserted
    #: against what actually lands on disk.
    approx_download_bytes: int


class ModelsResponse(BaseModel):
    """The whole picker state in one poll: what's active, what's on disk."""

    active: str
    models: list[ModelInfo]


class ModelSelection(BaseModel):
    name: str


class InstallAccepted(BaseModel):
    status: str = "installing"


class ProgressResponse(BaseModel):
    phase: Literal["idle", "downloading", "verifying", "done", "failed"]
    percent: int
    detail: str
    #: Which model the progress refers to; "" while idle. The client shows
    #: the name beside the bar, so it cannot be inferred from the request.
    model: str


class DeleteResponse(BaseModel):
    #: False when there were no weights to remove — delete is idempotent.
    deleted: bool


def _models_response(db: sqlite3.Connection) -> ModelsResponse:
    return ModelsResponse(
        active=resolve_active_model(db),
        models=[ModelInfo(**row) for row in whisper_models.inventory()],
    )


@router.get("/v1/transcription/models", response_model=ModelsResponse)
def list_transcription_models(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> ModelsResponse:
    """Active selection + every supported model in ACCURACY order.

    The client renders ``models`` directly, so the order is the server's
    responsibility (Jeff's accuracy-first copy rule), not the client's.
    """
    return _models_response(db)


@router.put("/v1/transcription/model", response_model=ModelsResponse)
def select_transcription_model(
    payload: ModelSelection,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> ModelsResponse:
    """Choose the model every future transcription uses.

    400 for a name outside SUPPORTED_MODELS. **409 when the model is not
    installed** — selection and install are deliberately separate steps, so
    the client installs first and selects second (the summaries regenerate
    contract). On success the cached TranscriptionService is dropped, so the
    NEXT job loads the new weights without a container restart.
    """
    name = payload.name
    if not is_supported_model(name):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported model {name!r}",
        )
    if not whisper_models.is_installed(name):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Model {name!r} is not installed; install it first",
        )
    set_active_model(db, name)
    # Requirement 7: the service caches its loaded model, so a selection
    # that does not invalidate the cache silently keeps transcribing with
    # the OLD weights until the container restarts.
    reset_transcription_service()
    log.info("transcription.model_selected", model=name)
    return _models_response(db)


@router.post(
    "/v1/transcription/models/{name}/install",
    response_model=InstallAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
def start_model_install(
    name: str,
    _user: Annotated[str, Depends(require_auth)],
) -> InstallAccepted:
    """Download one model's weights in a background thread (202).

    Progress is polled via /v1/transcription/models/install/progress. A
    second install while one is running is a 409 — the client treats that as
    attach, never an error (wizard rehydration contract). **Installing does
    NOT change the active model**: selection is an explicit second step, so
    a download never silently changes what the server transcribes with.
    """
    if not is_supported_model(name):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported model {name!r}",
        )
    try:
        whisper_models.start_install(name)
    except whisper_models.InstallInProgress as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A whisper model install is already running",
        ) from exc
    log.info("transcription.model_install_requested", model=name)
    return InstallAccepted()


@router.get(
    "/v1/transcription/models/install/progress", response_model=ProgressResponse
)
def get_model_install_progress(
    _user: Annotated[str, Depends(require_auth)],
) -> ProgressResponse:
    """Current install progress. Non-blocking; safe to poll while installing."""
    return ProgressResponse(**whisper_models.progress())


@router.delete("/v1/transcription/models/{name}", response_model=DeleteResponse)
def delete_transcription_model(
    name: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> DeleteResponse:
    """Remove one model's weights from disk.

    400 for an unsupported name. **409 when it is the ACTIVE model** — never
    leave the server unable to transcribe (requirement 6); the client selects
    something else first. Also 409 while an install is running, because
    deleting under a live download is how you get a half-tree that reads as
    installed. ``deleted: false`` (200) when there was nothing there:
    removing absent weights is the state the caller asked for, not an error.
    """
    if not is_supported_model(name):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported model {name!r}",
        )
    # Active check FIRST, before the install-running check: the
    # active-model rule is then unambiguous — deleting the live model is
    # always refused for the same reason, whatever else is happening.
    if name == resolve_active_model(db):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Model {name!r} is the active transcription model; "
                "select another model before deleting it"
            ),
        )
    try:
        deleted = whisper_models.delete_model(name)
    except whisper_models.InstallInProgress as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Cannot delete a model while an install is running",
        ) from exc
    return DeleteResponse(deleted=deleted)

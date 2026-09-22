# SPDX-License-Identifier: AGPL-3.0-or-later
"""OCR endpoints: environment install management + index status."""

from __future__ import annotations

import sqlite3
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.services import ocr_env, ocr_worker

router = APIRouter()

log = get_logger(__name__)


class CapabilityResponse(BaseModel):
    installed: bool
    flavour: Literal["gpu", "cpu"] | None
    gpu_visible: bool
    disk_free_bytes: int
    install_running: bool


class InstallRequest(BaseModel):
    flavour: Literal["gpu", "cpu"]


class InstallAccepted(BaseModel):
    flavour: Literal["gpu", "cpu"]
    status: str = "installing"


class ProgressResponse(BaseModel):
    phase: Literal[
        "idle", "venv", "torch", "transformers", "weights", "verify", "done", "failed"
    ]
    percent: int
    detail: str


class UninstallResponse(BaseModel):
    uninstalled: bool


class IndexStatusResponse(BaseModel):
    installed: bool
    worker_running: bool
    #: Distinct notebooks with at least one index row.
    indexed_notebooks: int
    #: Successfully recognized word rows (model != 'error').
    indexed_words: int
    #: Rows written by a failed line inference.
    error_words: int
    #: Live, inked notebooks with no index rows at all.
    backlog: int
    #: Notebooks currently queued for (re)indexing.
    queue_depth: int


@router.get("/v1/ocr/capability", response_model=CapabilityResponse)
def get_capability(
    _user: Annotated[str, Depends(require_auth)],
) -> CapabilityResponse:
    """Install/GPU/disk state for the client's enable-OCR wizard."""
    return CapabilityResponse(**ocr_env.capability())


@router.post(
    "/v1/ocr/install",
    response_model=InstallAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
def start_install(
    payload: InstallRequest,
    _user: Annotated[str, Depends(require_auth)],
) -> InstallAccepted:
    """Kick off the environment install in a background thread (202).

    Progress is polled via /v1/ocr/install/progress. A second install while
    one is running is a 409.
    """
    try:
        ocr_env.start_install(payload.flavour)
    except ocr_env.InstallInProgress as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An OCR environment install is already running",
        ) from exc
    log.info("ocr_env.install_requested", flavour=payload.flavour)
    return InstallAccepted(flavour=payload.flavour)


@router.get("/v1/ocr/install/progress", response_model=ProgressResponse)
def get_install_progress(
    _user: Annotated[str, Depends(require_auth)],
) -> ProgressResponse:
    """Current install progress. Non-blocking; safe to poll while installing."""
    return ProgressResponse(**ocr_env.progress())


@router.post("/v1/ocr/uninstall", response_model=UninstallResponse)
def uninstall(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> UninstallResponse:
    """Delete the OCR venv + model weights and drop indexed handwriting text."""
    try:
        ocr_env.uninstall(db)
    except ocr_env.InstallInProgress as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Cannot uninstall while an install is running",
        ) from exc
    return UninstallResponse(uninstalled=True)


@router.get("/v1/ocr/status", response_model=IndexStatusResponse)
def get_index_status(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> IndexStatusResponse:
    """Index coverage + backlog, for the client's search-settings screen."""
    counts = db.execute(
        """
        SELECT COUNT(DISTINCT notebook_id) AS notebooks,
               SUM(CASE WHEN model != 'error' THEN 1 ELSE 0 END) AS words,
               SUM(CASE WHEN model = 'error' THEN 1 ELSE 0 END) AS errors
        FROM ink_index
        """
    ).fetchone()
    backlog = db.execute(
        """
        SELECT COUNT(*) AS n FROM notebooks
        WHERE deleted_at IS NULL
          AND ink IS NOT NULL
          AND id NOT IN (SELECT DISTINCT notebook_id FROM ink_index)
        """
    ).fetchone()
    return IndexStatusResponse(
        installed=ocr_env.python_path() is not None,
        worker_running=ocr_worker.worker_running(),
        indexed_notebooks=counts["notebooks"] or 0,
        indexed_words=counts["words"] or 0,
        error_words=counts["errors"] or 0,
        backlog=backlog["n"] or 0,
        queue_depth=len(ocr_worker.pending()),
    )

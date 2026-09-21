# SPDX-License-Identifier: AGPL-3.0-or-later
"""OCR environment endpoints: capability, install, progress, uninstall.

The handwriting-search index endpoints (/v1/ocr/status etc.) arrive with the
OCR worker in a later task — this router only manages the on-demand
torch/transformers environment install.
"""

from __future__ import annotations

import sqlite3
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.services import ocr_env

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

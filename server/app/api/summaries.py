# SPDX-License-Identifier: AGPL-3.0-or-later
"""AI-summaries endpoints: settings (capability + toggle), env install
management, and per-dump regenerate. Mirrors /v1/ocr/* in shape."""

from __future__ import annotations

import sqlite3
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.services import summarizer_env, summarizer_worker

router = APIRouter()

log = get_logger(__name__)


class SummarySettingsResponse(BaseModel):
    """Capability + toggle in one poll: everything the wizard needs."""

    installed: bool
    runtime: Literal["cuda", "cpu"] | None
    gpu_visible: bool
    disk_free_bytes: int
    install_running: bool
    #: The server-side auto-summarize toggle (auto-trigger gate).
    enabled: bool


class SummarySettingsUpdate(BaseModel):
    enabled: bool


class InstallAccepted(BaseModel):
    status: str = "installing"


class ProgressResponse(BaseModel):
    phase: Literal["idle", "venv", "runtime", "weights", "verify", "done", "failed"]
    percent: int
    detail: str


class UninstallResponse(BaseModel):
    uninstalled: bool


class SummarizeAccepted(BaseModel):
    dump_id: str
    status: str = "queued"


def _settings_response(db: sqlite3.Connection) -> SummarySettingsResponse:
    return SummarySettingsResponse(
        **summarizer_env.capability(),
        enabled=summarizer_worker.summaries_enabled(db),
    )


@router.get("/v1/summaries/settings", response_model=SummarySettingsResponse)
def get_summary_settings(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> SummarySettingsResponse:
    """Install/GPU/disk state + the auto-summarize toggle, for the client's
    AI-summaries settings section."""
    return _settings_response(db)


@router.post("/v1/summaries/settings", response_model=SummarySettingsResponse)
def update_summary_settings(
    payload: SummarySettingsUpdate,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> SummarySettingsResponse:
    """Persist the auto-summarize toggle server-side.

    The toggle gates a SERVER worker (the auto-trigger), so it lives in the
    server's settings table — a device toggling it changes behavior for
    every device.
    """
    summarizer_worker.set_summaries_enabled(db, payload.enabled)
    log.info("summaries.toggle_set", enabled=payload.enabled)
    return _settings_response(db)


@router.post(
    "/v1/summaries/install",
    response_model=InstallAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
def start_install(
    _user: Annotated[str, Depends(require_auth)],
) -> InstallAccepted:
    """Kick off the summarizer env install in a background thread (202).

    Progress is polled via /v1/summaries/install/progress. A second install
    while one is running is a 409 — the client treats that as attach, never
    an error (wizard rehydration contract).
    """
    try:
        summarizer_env.start_install()
    except summarizer_env.InstallInProgress as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A summarizer environment install is already running",
        ) from exc
    log.info("summarizer_env.install_requested")
    return InstallAccepted()


@router.get("/v1/summaries/install/progress", response_model=ProgressResponse)
def get_install_progress(
    _user: Annotated[str, Depends(require_auth)],
) -> ProgressResponse:
    """Current install progress. Non-blocking; safe to poll while installing."""
    return ProgressResponse(**summarizer_env.progress())


@router.post("/v1/summaries/uninstall", response_model=UninstallResponse)
def uninstall(
    _user: Annotated[str, Depends(require_auth)],
) -> UninstallResponse:
    """Delete the summarizer venv + model weights. Stored summaries are KEPT:
    they are user data — uninstall removes only the ability to generate new
    ones (the wizard's promise names both facts).
    """
    # Quiesce first: stop the worker and drop its queue BEFORE the env wipe,
    # so no in-flight child holds the venv open and no queued dump runs
    # against a deleted env (ocr_env uninstall precedent).
    summarizer_worker.stop_worker()
    summarizer_worker.clear_queue()
    try:
        summarizer_env.uninstall()
    except summarizer_env.InstallInProgress as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Cannot uninstall while an install is running",
        ) from exc
    return UninstallResponse(uninstalled=True)


@router.post(
    "/v1/dumps/{dump_id}/summarize",
    response_model=SummarizeAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
def summarize_dump(
    dump_id: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> SummarizeAccepted:
    """(Re)generate the summary for one dump: idempotent replace.

    Accepts ANY dump with a transcript, not just meetings — the meeting-only
    rule applies to the AUTO trigger, not to an explicit request. 404 for an
    unknown/deleted dump, 409 when there is no transcript to summarize, 409
    when the capability is not installed. The client polls the dump itself
    (summarized_at changes) to observe completion.
    """
    row = db.execute(
        "SELECT transcript FROM dumps WHERE id = ? AND deleted_at IS NULL",
        (dump_id,),
    ).fetchone()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )
    if not row["transcript"] or not row["transcript"].strip():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Dump has no transcript to summarize",
        )
    if summarizer_env.python_path() is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Summarizer environment is not installed",
        )
    summarizer_worker.enqueue(dump_id)
    summarizer_worker.start_worker_if_installed()
    log.info("summaries.regenerate_requested", dump_id=dump_id)
    return SummarizeAccepted(dump_id=dump_id)

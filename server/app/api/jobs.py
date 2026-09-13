# SPDX-License-Identifier: AGPL-3.0-or-later
"""Transcription job endpoints: enqueue, poll, SSE stream."""

from __future__ import annotations

import asyncio
import sqlite3
import time
from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from sse_starlette.sse import EventSourceResponse

from app.auth import require_auth
from app.db import get_db
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
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )

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
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id!r} not found",
        )
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
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job {job_id!r} not found",
        )

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

            current_status = row["status"]
            if current_status != last_status:
                payload = {"status": current_status}
                if current_status == "completed":
                    payload["transcript"] = row["result_transcript"]
                elif current_status == "failed":
                    payload["error"] = row["error"]
                yield {"event": current_status, "data": str(payload)}
                last_status = current_status

            if current_status in ("completed", "failed"):
                return

            await asyncio.sleep(1)

        yield {"event": "timeout", "data": "job did not complete within 30 minutes"}

    return EventSourceResponse(event_generator())
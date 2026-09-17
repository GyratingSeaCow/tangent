# SPDX-License-Identifier: AGPL-3.0-or-later
"""Transcription job endpoints: enqueue, poll, SSE stream."""

from __future__ import annotations

import asyncio
import json
import sqlite3
import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Response, status
from sse_starlette.sse import EventSourceResponse

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.models import JobCreate, JobResponse
from app.services.job_queue import RequestIdConflict, enqueue_job, run_job_inline

router = APIRouter()

log = get_logger(__name__)


def _to_iso(ts: int | None) -> datetime | None:
    return datetime.fromtimestamp(ts, tz=UTC) if ts else None


def _row_to_job(row: sqlite3.Row) -> JobResponse:
    return JobResponse(
        id=row["id"],
        request_id=row["request_id"],
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
    response: Response,
    background_tasks: BackgroundTasks,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> JobResponse:
    """Create or replay an idempotent transcription job."""
    dump_row = db.execute(
        "SELECT id FROM dumps WHERE id = ? AND deleted_at IS NULL", (dump_id,)
    ).fetchone()
    if dump_row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Dump {dump_id!r} not found",
        )

    request_id = payload.request_id or f"legacy:{uuid.uuid4()}"
    existing = db.execute(
        "SELECT id FROM jobs WHERE request_id = ?", (request_id,)
    ).fetchone()
    if existing is not None:
        try:
            job_id, _created = enqueue_job(db, dump_id, payload.model, request_id)
        except RequestIdConflict as exc:
            raise HTTPException(status_code=409, detail="request_id conflict") from exc
        response.status_code = status.HTTP_200_OK
        row = db.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _row_to_job(row)

    from app.api.dumps import get_audio_path_for_dump

    audio_path_obj = get_audio_path_for_dump(dump_id)
    if audio_path_obj is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"No audio file uploaded for dump {dump_id!r}. "
                "POST the audio to /v1/dumps/{id}/audio first."
            ),
        )
    audio_path = str(audio_path_obj)

    try:
        job_id, created = enqueue_job(db, dump_id, payload.model, request_id)
    except RequestIdConflict as exc:
        raise HTTPException(status_code=409, detail="request_id conflict") from exc

    response.status_code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    if created:
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

    request_id = row["request_id"]

    async def event_generator():
        last_status: str | None = None
        # Poll for up to 30 minutes
        for _ in range(1800):
            row = db.execute(
                "SELECT status, request_id, result_transcript, error FROM jobs WHERE id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                yield {
                    "event": "error",
                    "data": json.dumps(
                        {
                            "status": "error",
                            "request_id": request_id,
                            "error": "job disappeared",
                        }
                    ),
                }
                return

            current_status = row["status"]
            if current_status != last_status:
                payload = {
                    "status": current_status,
                    "request_id": row["request_id"],
                }
                if current_status == "completed":
                    payload["transcript"] = row["result_transcript"]
                elif current_status == "failed":
                    payload["error"] = row["error"]
                yield {"event": current_status, "data": json.dumps(payload)}
                last_status = current_status

            if current_status in ("completed", "failed"):
                return

            await asyncio.sleep(1)

        yield {
            "event": "timeout",
            "data": json.dumps(
                {
                    "status": "timeout",
                    "request_id": request_id,
                    "error": "job did not complete within 30 minutes",
                }
            ),
        }

    return EventSourceResponse(event_generator())

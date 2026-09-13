# SPDX-License-Identifier: AGPL-3.0-or-later
"""In-process transcription job runner.

For v1 single-user: jobs run inline using FastAPI BackgroundTasks. No Celery,
no Redis. If the process crashes mid-job, the job is marked failed on next
startup. Good enough for one user on one server.
"""

from __future__ import annotations

import sqlite3
import time
import uuid

from app.logging_config import get_logger
from app.services.transcription import get_transcription_service

log = get_logger(__name__)


def _now_ts() -> int:
    return int(time.time())


def enqueue_job(
    db: sqlite3.Connection,
    dump_id: str,
    model: str,
    audio_path: str,
) -> str:
    """Create a job row in 'queued' state. Returns the job id."""
    job_id = str(uuid.uuid4())
    db.execute(
        """
        INSERT INTO jobs (id, dump_id, status, model, started_at)
        VALUES (?, ?, 'queued', ?, NULL)
        """,
        (job_id, dump_id, model),
    )
    log.info("job.queued", job_id=job_id, dump_id=dump_id, model=model)
    return job_id


def run_job_inline(job_id: str, audio_path: str) -> None:
    """Execute a job synchronously. Updates job status as it progresses.

    Intended to be called from a FastAPI BackgroundTasks hook.
    Opens its own DB connection (the request's connection is closed by then).
    """
    from app.db import get_db

    log.info("job.starting", job_id=job_id, audio=audio_path)

    # Open a fresh connection for the background work
    gen = get_db()
    db = next(gen)
    try:
        # Mark as running
        db.execute(
            "UPDATE jobs SET status = 'running', started_at = ? WHERE id = ?",
            (_now_ts(), job_id),
        )
        db.commit()

        # Look up the job's model choice
        row = db.execute("SELECT model FROM jobs WHERE id = ?", (job_id,)).fetchone()
        if row is None:
            log.error("job.disappeared", job_id=job_id)
            return
        model_name = row["model"]

        try:
            # Defensive: skip if audio file doesn't exist (v1: audio upload is Phase 1.5)
            import os
            if not os.path.exists(audio_path):
                raise FileNotFoundError(f"Audio file not found at {audio_path}")

            service = get_transcription_service()
            transcript = service.transcribe(audio_path)

            db.execute(
                """
                UPDATE jobs SET status = 'completed', completed_at = ?,
                                result_transcript = ?
                WHERE id = ?
                """,
                (_now_ts(), transcript, job_id),
            )
            # Also update the dump's transcript if not already set or if server transcript is better
            db.execute(
                "UPDATE dumps SET transcript = ?, updated_at = ? "
                "WHERE id = (SELECT dump_id FROM jobs WHERE id = ?)",
                (transcript, _now_ts(), job_id),
            )
            log.info("job.completed", job_id=job_id, length=len(transcript))

        except Exception as exc:
            log.exception("job.failed", job_id=job_id)
            db.execute(
                """
                UPDATE jobs SET status = 'failed', completed_at = ?, error = ?
                WHERE id = ?
                """,
                (_now_ts(), str(exc), job_id),
            )

        db.commit()
    finally:
        try:
            next(gen)
        except StopIteration:
            pass
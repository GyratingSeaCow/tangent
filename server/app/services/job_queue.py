# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-License-Identifier: AGPL-3.0-or-later
"""In-process transcription job runner.

For v1 single-user: jobs run inline using FastAPI BackgroundTasks. No Celery,
no Redis. If the process crashes mid-job, the job is marked failed on next
startup. Good enough for one user on one server.
"""

from __future__ import annotations

import contextlib
import json
import sqlite3
import time
import uuid

from app.logging_config import get_logger
from app.services.transcription import get_transcription_service

log = get_logger(__name__)


def _now_ts() -> int:
    return int(time.time())


def fail_interrupted_jobs(db: sqlite3.Connection) -> int:
    """Fail jobs whose in-process owner disappeared during a server restart."""
    completed_at = _now_ts()
    cursor = db.execute(
        """
        UPDATE jobs
        SET status = 'failed', completed_at = ?,
            error = 'Server restarted before transcription completed'
        WHERE status IN ('queued', 'running')
        """,
        (completed_at,),
    )
    db.commit()
    if cursor.rowcount:
        log.warning("job.interrupted", count=cursor.rowcount)
    return cursor.rowcount


class RequestIdConflict(Exception):  # noqa: N818
    """A request ID was already used for a different dump or model."""


def enqueue_job(
    db: sqlite3.Connection,
    dump_id: str,
    model: str,
    request_id: str,
) -> tuple[str, bool]:
    """Create a queued job, or return an identical request's existing job."""
    existing = db.execute(
        "SELECT id, dump_id, model FROM jobs WHERE request_id = ?", (request_id,)
    ).fetchone()
    if existing is not None:
        if existing["dump_id"] == dump_id and existing["model"] == model:
            return existing["id"], False
        raise RequestIdConflict(request_id)

    job_id = str(uuid.uuid4())
    try:
        db.execute(
            """
            INSERT INTO jobs (id, request_id, dump_id, status, model, started_at)
            VALUES (?, ?, ?, 'queued', ?, NULL)
            """,
            (job_id, request_id, dump_id, model),
        )
        db.commit()
    except sqlite3.IntegrityError:
        db.rollback()
        existing = db.execute(
            "SELECT id, dump_id, model FROM jobs WHERE request_id = ?", (request_id,)
        ).fetchone()
        if existing is not None:
            if existing["dump_id"] == dump_id and existing["model"] == model:
                return existing["id"], False
            raise RequestIdConflict(request_id) from None
        raise
    log.info("job.queued", job_id=job_id, dump_id=dump_id, model=model)
    return job_id, True


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

        try:
            # Defensive: skip if audio file doesn't exist (v1: audio upload is Phase 1.5)
            import os
            if not os.path.exists(audio_path):
                raise FileNotFoundError(f"Audio file not found at {audio_path}")

            service = get_transcription_service()
            result = service.transcribe(audio_path)
            transcript = result.text
            # Segment timings describe the raw audio, so they are stored as
            # transcribed and are NOT rewritten by mode-specific formatting.
            segments_json = json.dumps(result.segments)

            # For 'meeting' mode, extract action items and format as a summary.
            dump_row = db.execute(
                "SELECT mode FROM dumps WHERE id = "
                "(SELECT dump_id FROM jobs WHERE id = ?)",
                (job_id,),
            ).fetchone()
            if dump_row and dump_row["mode"] == "meeting":
                from app.services.secretary import (
                    extract_action_items,
                    format_meeting_summary,
                )
                action_items = extract_action_items(transcript)
                transcript = format_meeting_summary(transcript, action_items)
                log.info(
                    "job.meeting_formatted",
                    job_id=job_id,
                    action_items=len(action_items),
                )

            db.execute(
                """
                UPDATE jobs SET status = 'completed', completed_at = ?,
                                result_transcript = ?, result_segments = ?
                WHERE id = ?
                """,
                (_now_ts(), transcript, segments_json, job_id),
            )
            # Also update the dump's transcript if not already set or if server transcript is better
            db.execute(
                "UPDATE dumps SET transcript = ?, updated_at = ? "
                "WHERE id = (SELECT dump_id FROM jobs WHERE id = ?)",
                (transcript, _now_ts(), job_id),
            )
            log.info(
                "job.completed",
                job_id=job_id,
                length=len(transcript),
                segments=len(result.segments),
            )

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
        with contextlib.suppress(StopIteration):
            next(gen)

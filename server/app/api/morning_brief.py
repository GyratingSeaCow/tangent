# SPDX-License-Identifier: AGPL-3.0-or-later
"""GET /v1/morning-brief — the cached daily brief (v1.41).

Contract (docs/design/2026-10-01-morning-brief.md):
  200 {date, brief_md, generated_at, model}
  404 not generated for that date (yet)
  409 the capability is unavailable — the client HIDES the section.

The two 409 ``detail`` strings below are LOAD-BEARING: the client's
``SummariesClient.getMorningBrief`` classifies them (``disabled`` →
disabled, anything else → notInstalled). Change them only together.
"""

from __future__ import annotations

import sqlite3
import threading
from datetime import date, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.services import morning_brief

router = APIRouter()

#: Client-coupled 409 details (see module doc).
DETAIL_NOT_INSTALLED = "Summarizer environment is not installed"
DETAIL_DISABLED = "AI summaries are disabled"
DETAIL_NOT_GENERATED = "Morning brief not generated"


class MorningBriefResponse(BaseModel):
    date: str
    brief_md: str
    generated_at: int
    model: str


class MorningBriefAccepted(BaseModel):
    date: str
    status: str = "generating"


def _day(raw: str | None) -> date:
    if raw is None:
        return datetime.now().astimezone().date()
    try:
        return date.fromisoformat(raw)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="date must be YYYY-MM-DD",
        ) from exc


def _gate(db: sqlite3.Connection) -> None:
    reason = morning_brief.available(db)
    if reason is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=DETAIL_DISABLED if reason == "disabled" else DETAIL_NOT_INSTALLED,
        )


@router.get("/v1/morning-brief", response_model=MorningBriefResponse)
def get_morning_brief(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    date_: Annotated[str | None, Query(alias="date")] = None,
) -> MorningBriefResponse:
    """Cheap cached read. Gate first: a brief cached before the capability
    was turned off is not served (the section must disappear)."""
    day = _day(date_)
    _gate(db)
    row = morning_brief.get_brief(db, day)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=DETAIL_NOT_GENERATED
        )
    return MorningBriefResponse(
        date=row["date"],
        brief_md=row["brief_md"],
        generated_at=row["generated_at"],
        model=row["model"],
    )


@router.post(
    "/v1/morning-brief/generate",
    response_model=MorningBriefAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
def regenerate_morning_brief(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
    date_: Annotated[str | None, Query(alias="date")] = None,
) -> MorningBriefAccepted:
    """Explicit (re)generate — the only path that replaces a cached brief.
    Runs in the background (CPU inference takes ~30-60 s); poll the GET."""
    day = _day(date_)
    _gate(db)
    threading.Thread(
        target=morning_brief.generate_now,
        args=(day,),
        name="morning-brief-regenerate",
        daemon=True,
    ).start()
    return MorningBriefAccepted(date=day.isoformat())

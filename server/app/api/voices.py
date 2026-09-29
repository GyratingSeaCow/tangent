# SPDX-License-Identifier: AGPL-3.0-or-later
"""Settings → Voices: list remembered voices, forget one at a time."""
from __future__ import annotations

import sqlite3
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel

from app.auth import require_auth
from app.db import get_db
from app.services.voice_book import forget, load_voice_book

router = APIRouter(tags=["voices"])


class VoiceOut(BaseModel):
    name: str
    samples: int
    updated_at: str


@router.get("/v1/voices", response_model=list[VoiceOut])
def list_voices(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _auth: Annotated[str, Depends(require_auth)],
) -> list[VoiceOut]:
    """List remembered display names newest-first without exposing embeddings."""
    return [
        VoiceOut(name=e.name, samples=e.samples, updated_at=e.updated_at)
        for e in load_voice_book(db)
    ]


@router.delete("/v1/voices/{name:path}", status_code=status.HTTP_204_NO_CONTENT)
def forget_voice(
    name: str,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _auth: Annotated[str, Depends(require_auth)],
) -> Response:
    """Forget one exact display name; existing recording maps stay unchanged."""
    # A display name, never an entity id: looked up, never used as a path.
    if not forget(db, name):
        raise HTTPException(status_code=404, detail="unknown voice")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)

# SPDX-License-Identifier: AGPL-3.0-or-later
"""Model management: list, pull."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import require_auth
from app.services.storage import SUPPORTED_MODELS, is_supported_model

router = APIRouter()


class PullResponse(BaseModel):
    model: str
    status: str  # "already_loaded" | "queued" | "downloaded"


@router.get("/v1/models", response_model=list[str])
def list_models(
    _user: Annotated[str, Depends(require_auth)],
) -> list[str]:
    """List Whisper models this server supports."""
    return list(SUPPORTED_MODELS)


@router.post("/v1/models/{model_name}/pull", response_model=PullResponse)
def pull_model(
    model_name: str,
    _user: Annotated[str, Depends(require_auth)],
) -> PullResponse:
    """Trigger download of a model.

    v1 stub: faster-whisper downloads lazily on first transcribe(). This endpoint
    pre-warms the cache by calling load_model() in a thread.
    """
    if not is_supported_model(model_name):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unknown model {model_name!r}. Supported: {list(SUPPORTED_MODELS)}",
        )

    from app.services.transcription import get_transcription_service

    service = get_transcription_service()
    if service.model_name == model_name and service._model is not None:
        return PullResponse(model=model_name, status="already_loaded")

    # Trigger download
    service.load_model(model_name)
    return PullResponse(model=model_name, status="downloaded")

# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pydantic request/response models."""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

DumpMode = Literal["brain_dump", "meeting"]
JobStatus = Literal["queued", "running", "completed", "failed"]


class SetupRequest(BaseModel):
    """First-time setup payload. Empty if no display name yet."""

    display_name: str = Field(min_length=1, max_length=100)

    @field_validator("display_name")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("display_name cannot be empty after stripping")
        return v


class SetupResponse(BaseModel):
    """Setup response. Token only returned on first call."""

    token: str
    display_name: str
    setup_completed_at: datetime | None


class DumpCreate(BaseModel):
    """Metadata for a new dump. Audio is uploaded separately via multipart."""

    id: str = Field(min_length=8, max_length=64)
    mode: DumpMode
    duration_seconds: int = Field(ge=0, le=7200)  # 0 to 2 hours
    title: str = Field(min_length=1, max_length=500)
    created_at: datetime


class DumpPatch(BaseModel):
    """Editable fields on a dump."""

    title: str | None = Field(default=None, min_length=1, max_length=500)


class DumpResponse(BaseModel):
    id: str
    mode: DumpMode
    title: str
    transcript: str | None
    duration_seconds: int
    created_at: datetime
    updated_at: datetime


class DumpListResponse(BaseModel):
    dumps: list[DumpResponse]
    total: int
    limit: int
    offset: int


class JobCreate(BaseModel):
    """Request to enqueue a transcription job."""

    model: str = Field(default="large-v3", min_length=1, max_length=50)
    request_id: str = Field(min_length=8, max_length=128)


class JobResponse(BaseModel):
    id: str
    request_id: str
    dump_id: str
    status: JobStatus
    model: str
    started_at: datetime | None
    completed_at: datetime | None
    result_transcript: str | None
    error: str | None


class ServerInfo(BaseModel):
    version: str
    setup_complete: bool
    default_model: str
    available_models: list[str]
    storage_used_bytes: int
    dump_count: int

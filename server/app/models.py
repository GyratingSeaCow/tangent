# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pydantic request/response models."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

DumpMode = Literal["brain_dump", "meeting", "text_note"]
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
    transcript_timings: str | None
    timings_version: int | None
    duration_seconds: int
    created_at: datetime
    updated_at: datetime


class DumpListResponse(BaseModel):
    dumps: list[DumpResponse]
    total: int
    limit: int
    offset: int


class TranscriptSegment(BaseModel):
    """One timed chunk of a transcript.

    start/end are elapsed seconds from the start of the audio (not wall-clock).
    speaker is null unless speaker diarization actually ran.
    """

    start: float
    end: float
    speaker: str | None = None
    text: str


class JobCreate(BaseModel):
    """Request to enqueue a transcription job.

    ``model`` is optional: when omitted the server resolves its own selected
    model (``storage.resolve_active_model``) at enqueue time, so the job row
    records what the engine will actually load instead of a client-side
    guess that can drift from the server's selection.
    """

    model: str | None = Field(default=None, min_length=1, max_length=50)
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
    segments: list[TranscriptSegment] | None = None
    error: str | None


class ServerInfo(BaseModel):
    version: str
    setup_complete: bool
    default_model: str
    available_models: list[str]
    storage_used_bytes: int
    dump_count: int


class PublicServerInfo(BaseModel):
    """The UNAUTHENTICATED discovery form. Only what a subnet sweep needs to
    say "that host is a Tangent server named X" — never storage, counts,
    models, or anything else the full form carries behind auth."""

    service: str = "tangent"
    name: str
    version: str
    requires_auth: bool


# --- Pairing ----------------------------------------------------------------


class PairRequest(BaseModel):
    device_id: str = Field(min_length=8, max_length=64)
    display_name: str = Field(min_length=1, max_length=80)
    platform: str = Field(min_length=1, max_length=32)


class PairRequestResponse(BaseModel):
    pair_id: str
    expires_at: datetime


class PairClaim(BaseModel):
    pair_id: str = Field(min_length=1, max_length=64)
    code: str = Field(min_length=1, max_length=16)


class PairClaimResponse(BaseModel):
    token: str
    server_name: str
    device_id: str


class PairPendingEntry(BaseModel):
    pair_id: str
    display_name: str
    platform: str
    requested_at: datetime
    code: str


class PairPendingResponse(BaseModel):
    pending: list[PairPendingEntry]


# --- Multi-device sync ----------------------------------------------------


class DeviceRegister(BaseModel):
    """Registers a replica. Idempotent: re-running it updates the name.

    ``device_id`` identifies the REPLICA; the existing bearer token still
    identifies the user. Multi-device does not imply multi-user auth.
    """

    device_id: str = Field(min_length=8, max_length=64)
    display_name: str = Field(min_length=1, max_length=200)
    platform: str = Field(min_length=1, max_length=64)


class DeviceResponse(BaseModel):
    device_id: str
    display_name: str
    platform: str
    last_seen_seq: int
    last_seen_at: datetime | None


class DeviceListResponse(BaseModel):
    devices: list[DeviceResponse]


class SyncChange(BaseModel):
    """One mutation, as carried in either direction.

    ``payload`` is the full entity for an upsert and null for a delete. The
    server stores it opaquely: it never needs to understand ink, so a
    client-side document change does not require a server deploy.

    ``ink_index`` travels pull-only: the server builds its payload from the
    live index at pull time, and a client push of it is rejected per-entity
    (the wire model still admits it so the rejection is a result row, not an
    opaque 422 that would strand the rest of the batch).
    """

    entity_type: Literal["dump", "notebook", "note", "folder", "ink_index"]
    entity_id: str = Field(min_length=1, max_length=64)
    op: Literal["upsert", "delete"]
    payload: dict[str, Any] | None = None
    #: Server-assigned. Ignored on push, populated on pull.
    seq: int | None = None
    device_id: str | None = None


class SyncPullResponse(BaseModel):
    changes: list[SyncChange]
    #: The checkpoint to store once every change above has been applied.
    head_seq: int
    #: True when more changes remain past this page.
    has_more: bool


class SyncPushRequest(BaseModel):
    device_id: str = Field(min_length=8, max_length=64)
    changes: list[SyncChange]


class SyncPushResult(BaseModel):
    entity_id: str
    entity_type: str
    seq: int
    status: Literal["applied", "rejected"]
    reason: str | None = None


class SyncPushResponse(BaseModel):
    results: list[SyncPushResult]
    head_seq: int

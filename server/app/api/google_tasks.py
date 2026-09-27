# SPDX-License-Identifier: AGPL-3.0-or-later
"""Authenticated Google Tasks connection and manual-sync endpoints."""

from __future__ import annotations

import base64
import json
import secrets
import sqlite3
import time
from typing import Annotated, Literal
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from app.auth import require_auth
from app.db import get_db
from app.logging_config import get_logger
from app.services import google_tasks_worker

router = APIRouter(prefix="/v1/google-tasks", tags=["google-tasks"])
log = get_logger(__name__)

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
OAUTH_SCOPE = "https://www.googleapis.com/auth/tasks openid email"
STATE_TTL_S = 10 * 60

GoogleLinkStatus = Literal[
    "disconnected", "pending", "connected", "reauth_required", "error"
]


class GoogleTasksStatus(BaseModel):
    status: GoogleLinkStatus
    credentials_configured: bool
    google_email: str | None = None
    last_sync_at: str | None = None
    last_error: str | None = None
    pushed: int = 0
    pulled: int = 0


class GoogleCredentials(BaseModel):
    client_id: str = Field(min_length=1, max_length=1000)
    client_secret: str = Field(min_length=1, max_length=1000)


class ConnectResponse(BaseModel):
    auth_url: str


def _link(db: sqlite3.Connection) -> sqlite3.Row | None:
    return db.execute("SELECT * FROM google_tasks_link WHERE id = 1").fetchone()


def _status(db: sqlite3.Connection) -> GoogleTasksStatus:
    row = _link(db)
    if row is None:
        return GoogleTasksStatus(status="disconnected", credentials_configured=False)
    return GoogleTasksStatus(
        status=row["status"],
        credentials_configured=bool(row["client_id"] and row["client_secret"]),
        google_email=row["google_email"],
        last_sync_at=row["last_sync_at"],
        last_error=row["last_error"],
        pushed=row["last_pushed"],
        pulled=row["last_pulled"],
    )


def _email_from_id_token(raw_token: object) -> str | None:
    """Read the email claim from the TLS-delivered token response.

    This is display metadata, not an authorization decision. The authorization
    code, access token, and state nonce are what protect the connection.
    """
    if not isinstance(raw_token, str):
        return None
    parts = raw_token.split(".")
    if len(parts) != 3:
        return None
    try:
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    email = payload.get("email") if isinstance(payload, dict) else None
    return str(email) if email else None


def _redirect_uri(request: Request) -> str:
    return str(request.url_for("google_tasks_callback"))


@router.get("/status", response_model=GoogleTasksStatus)
def get_status(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> GoogleTasksStatus:
    return _status(db)


@router.post("/credentials", response_model=GoogleTasksStatus)
def save_credentials(
    payload: GoogleCredentials,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> GoogleTasksStatus:
    client_id = payload.client_id.strip()
    client_secret = payload.client_secret.strip()
    if not client_id or not client_secret:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="client_id and client_secret cannot be blank",
        )
    db.execute(
        """
        INSERT INTO google_tasks_link (id, client_id, client_secret, status)
        VALUES (1, ?, ?, 'disconnected')
        ON CONFLICT(id) DO UPDATE SET
            client_id = excluded.client_id,
            client_secret = excluded.client_secret,
            refresh_token = NULL,
            access_token = NULL,
            access_expires_at = NULL,
            google_email = NULL,
            tasklist_id = NULL,
            last_pull_updated_min = NULL,
            status = 'disconnected',
            last_error = NULL,
            last_sync_at = NULL,
            last_pushed = 0,
            last_pulled = 0,
            oauth_state = NULL,
            oauth_state_expires_at = NULL
        """,
        (client_id, client_secret),
    )
    log.info("google_tasks.credentials_saved")
    return _status(db)


@router.post("/connect", response_model=ConnectResponse)
def connect(
    request: Request,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> ConnectResponse:
    row = _link(db)
    if row is None or not row["client_id"] or not row["client_secret"]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Google OAuth credentials are not configured",
        )
    nonce = secrets.token_urlsafe(32)
    db.execute(
        "UPDATE google_tasks_link SET status = 'pending', last_error = NULL, "
        "oauth_state = ?, oauth_state_expires_at = ? WHERE id = 1",
        (nonce, int(time.time()) + STATE_TTL_S),
    )
    query = urlencode(
        {
            "client_id": row["client_id"],
            "redirect_uri": _redirect_uri(request),
            "response_type": "code",
            "scope": OAUTH_SCOPE,
            "access_type": "offline",
            "prompt": "consent",
            "state": nonce,
        }
    )
    return ConnectResponse(auth_url=f"{AUTH_URL}?{query}")


@router.get("/callback", response_class=HTMLResponse, name="google_tasks_callback")
def callback(
    request: Request,
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    state_nonce: Annotated[str | None, Query(alias="state")] = None,
    code: str | None = None,
    error: str | None = None,
) -> HTMLResponse:
    """OAuth browser return. The one-use state nonce authenticates this route."""
    row = _link(db)
    valid_state = (
        row is not None
        and row["status"] == "pending"
        and isinstance(state_nonce, str)
        and isinstance(row["oauth_state"], str)
        and secrets.compare_digest(state_nonce, row["oauth_state"])
    )
    if not valid_state:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid OAuth state")
    if row["oauth_state_expires_at"] is None or int(row["oauth_state_expires_at"]) < int(
        time.time()
    ):
        db.execute(
            "UPDATE google_tasks_link SET status = 'disconnected', oauth_state = NULL, "
            "oauth_state_expires_at = NULL, last_error = 'OAuth state expired' WHERE id = 1"
        )
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="OAuth state expired")
    if error:
        db.execute(
            "UPDATE google_tasks_link SET status = 'disconnected', oauth_state = NULL, "
            "oauth_state_expires_at = NULL, last_error = ? WHERE id = 1",
            (f"Google authorization failed: {error}"[:500],),
        )
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Google authorization failed")
    if not code:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Missing OAuth code")

    try:
        tokens = google_tasks_worker.exchange_code(
            row["client_id"], row["client_secret"], code, _redirect_uri(request)
        )
        access_token = tokens.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise google_tasks_worker.GoogleTasksError(
                "Google token response did not include an access token"
            )
        refresh_token = tokens.get("refresh_token") or row["refresh_token"]
        if not isinstance(refresh_token, str) or not refresh_token:
            raise google_tasks_worker.GoogleTasksError(
                "Google token response did not include a refresh token"
            )
        expires_in = max(0, int(tokens.get("expires_in", 3600)))
        tasklist_id = google_tasks_worker.ensure_tangent_tasklist(access_token)
        email = tokens.get("email") or _email_from_id_token(tokens.get("id_token"))
    except (google_tasks_worker.GoogleTasksError, TypeError, ValueError) as exc:
        next_status = "reauth_required" if getattr(exc, "code", None) == "invalid_grant" else "error"
        db.execute(
            "UPDATE google_tasks_link SET status = ?, last_error = ?, oauth_state = NULL, "
            "oauth_state_expires_at = NULL WHERE id = 1",
            (next_status, str(exc)[:500]),
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Google connection failed",
        ) from exc

    db.execute(
        """
        UPDATE google_tasks_link SET
            refresh_token = ?, access_token = ?, access_expires_at = ?,
            google_email = ?, tasklist_id = ?, status = 'connected',
            last_error = NULL, oauth_state = NULL, oauth_state_expires_at = NULL
        WHERE id = 1
        """,
        (
            refresh_token,
            access_token,
            int(time.time()) + expires_in,
            str(email) if email else None,
            tasklist_id,
        ),
    )
    log.info("google_tasks.connected", has_email=bool(email))
    return HTMLResponse("Connected — you can close this tab")


@router.post("/disconnect", response_model=GoogleTasksStatus)
def disconnect(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> GoogleTasksStatus:
    row = _link(db)
    token = None if row is None else (row["refresh_token"] or row["access_token"])
    if token:
        try:
            google_tasks_worker.revoke_token(token)
        except google_tasks_worker.GoogleTasksError as exc:
            # Disconnect is a local guarantee. A failed revoke must not strand
            # credentials/tokens in the server DB or make the button unusable.
            log.warning("google_tasks.revoke_failed", error=str(exc))
    if row is not None:
        db.execute(
            """
            UPDATE google_tasks_link SET
                refresh_token = NULL, access_token = NULL,
                access_expires_at = NULL, google_email = NULL,
                tasklist_id = NULL, last_pull_updated_min = NULL,
                status = 'disconnected', last_error = NULL,
                last_sync_at = NULL, last_pushed = 0, last_pulled = 0,
                oauth_state = NULL, oauth_state_expires_at = NULL
            WHERE id = 1
            """
        )
    log.info("google_tasks.disconnected")
    return _status(db)


@router.post("/sync-now", response_model=GoogleTasksStatus)
def sync_now(
    db: Annotated[sqlite3.Connection, Depends(get_db)],
    _user: Annotated[str, Depends(require_auth)],
) -> GoogleTasksStatus:
    """Run one cycle inline. Error/reauth state is returned, not hidden."""
    google_tasks_worker.run_cycle(db)
    return _status(db)

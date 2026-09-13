# SPDX-License-Identifier: AGPL-3.0-or-later
"""Custom exceptions and FastAPI exception handlers."""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


class TangentError(Exception):
    """Base exception for Tangent-specific errors."""

    status_code: int = 500
    code: str = "internal_error"

    def __init__(self, message: str, *, code: str | None = None) -> None:
        super().__init__(message)
        self.message = message
        if code is not None:
            self.code = code


class NotFoundError(TangentError):
    status_code = 404
    code = "not_found"


class UnauthorizedError(TangentError):
    status_code = 401
    code = "unauthorized"


class ValidationError(TangentError):
    status_code = 422
    code = "validation_error"


class ConflictError(TangentError):
    status_code = 409
    code = "conflict"


def register_exception_handlers(app: FastAPI) -> None:
    """Register handlers that turn TangentErrors into JSON responses."""

    @app.exception_handler(TangentError)
    async def _handle_tangent_error(request: Request, exc: TangentError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": {"code": exc.code, "message": exc.message}},
        )

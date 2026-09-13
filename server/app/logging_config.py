# SPDX-License-Identifier: AGPL-3.0-or-later
"""structlog configuration. Single configure_logging() entry point."""

from __future__ import annotations

import logging
import sys

import structlog


def configure_logging(level: str = "info") -> None:
    """Configure structlog + stdlib logging. Call once at app startup."""
    log_level = getattr(logging, level.upper(), logging.INFO)

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=log_level,
    )

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_log_level,
            structlog.stdlib.add_logger_name,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.dev.ConsoleRenderer(colors=False),
        ],
        wrapper_class=structlog.stdlib.BoundLogger,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str | None = None) -> structlog.stdlib.BoundLogger:
    """Get a structlog logger."""
    return structlog.get_logger(name)

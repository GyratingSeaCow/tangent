# SPDX-License-Identifier: AGPL-3.0-or-later
"""Configuration via environment variables. Uses pydantic-settings."""

from __future__ import annotations

from functools import lru_cache

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

VALID_LOG_LEVELS = {"debug", "info", "warning", "error", "critical"}


class Settings(BaseSettings):
    """Server settings. All overridable via TANGENT_* env vars."""

    model_config = SettingsConfigDict(
        env_prefix="TANGENT_",
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    data_dir: str = "./data"
    log_level: str = "info"
    host: str = "0.0.0.0"
    port: int = 8000
    whisper_model: str = "large-v3"

    @field_validator("log_level")
    @classmethod
    def _validate_log_level(cls, v: str) -> str:
        if v.lower() not in VALID_LOG_LEVELS:
            raise ValueError(f"log_level must be one of {VALID_LOG_LEVELS}, got {v!r}")
        return v.lower()

    @field_validator("port")
    @classmethod
    def _validate_port(cls, v: int) -> int:
        if not (1 <= v <= 65535):
            raise ValueError(f"port must be 1-65535, got {v}")
        return v


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Cached settings instance. Re-read env on first call only."""
    return Settings()

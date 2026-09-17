# SPDX-License-Identifier: AGPL-3.0-or-later
# Tangent server container image.
FROM python:3.11-slim AS base

# System deps for faster-whisper (ffmpeg) + audio handling
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /app

# Install deps first (cache layer)
COPY pyproject.toml ./
# TANGENT_WITH_DIARIZATION=1 pulls in the optional pyannote.audio stack
# (large: torch + models). Left off by default to keep the image lean.
ARG TANGENT_WITH_DIARIZATION=0
RUN if [ "$TANGENT_WITH_DIARIZATION" = "1" ]; then \
        uv pip install --system --no-cache ".[diarization]"; \
    else \
        uv pip install --system --no-cache .; \
    fi

# Copy app code
COPY app ./app

# Data directory (mounted as volume in compose)
RUN mkdir -p /data
ENV TANGENT_DATA_DIR=/data
ENV TANGENT_HOST=0.0.0.0
ENV TANGENT_PORT=8000

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/v1/server/info || exit 1

# Run server (use uvicorn factory so the lifespan event handler runs properly)
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
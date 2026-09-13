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
RUN uv pip install --system --no-cache .

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

# Run server
CMD ["python", "-m", "app"]
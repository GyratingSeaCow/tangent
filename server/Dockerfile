# SPDX-License-Identifier: AGPL-3.0-or-later
# Tangent server container image.
#
# Build args:
#   TANGENT_WITH_DIARIZATION=1  install the optional pyannote.audio stack.
#   TANGENT_GPU=1               install CUDA-enabled torch + the CUDA-12
#                               runtime wheels (~9 GB extra). Default is the
#                               CPU-only build — GPU hosts build with
#                               docker-compose.gpu.yml, which sets this arg.
FROM python:3.11-slim-bookworm AS base

# System deps for faster-whisper (ffmpeg) + audio handling. Also pull in the
# distro security fixes that lag behind the slim base image. curl is NOT
# installed: the healthcheck uses the Python stdlib instead.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install deps first (cache layer). uv is bind-mounted from its pinned image
# for the install steps only, so no package manager ships in the final image.
COPY pyproject.toml ./
ARG TANGENT_WITH_DIARIZATION=0
ARG TANGENT_GPU=0
# CPU-only builds (the default) pre-install the +cpu torch wheel so the
# diarization extra doesn't drag in the ~5 GB CUDA torch stack that can
# never execute on a GPU-less host. GPU builds skip the pin and let the
# regular CUDA wheel resolve.
RUN --mount=from=ghcr.io/astral-sh/uv:0.9,source=/uv,target=/usr/local/bin/uv \
    set -e; \
    if [ "$TANGENT_WITH_DIARIZATION" = "1" ] && [ "$TANGENT_GPU" != "1" ]; then \
        uv pip install --system --no-cache \
            --index-url https://download.pytorch.org/whl/cpu \
            --extra-index-url https://pypi.org/simple \
            --index-strategy unsafe-best-match \
            torch torchaudio; \
    fi; \
    if [ "$TANGENT_WITH_DIARIZATION" = "1" ]; then \
        uv pip install --system --no-cache ".[diarization]"; \
    else \
        uv pip install --system --no-cache .; \
    fi

# ctranslate2 (faster-whisper's engine) links the CUDA-12 runtime
# (libcublas.so.12, libcudnn_ops.so.9). torch's transitive nvidia-* wheels
# are CUDA-13 and do NOT satisfy it — without the cu12 set, GPU visibility
# tricks device probes while first inference dies mid-request.
# resolve_whisper_device() still probes before selecting cuda. GPU builds
# only — on CPU hosts the wheels are 2.3 GB of dead weight.
RUN --mount=from=ghcr.io/astral-sh/uv:0.9,source=/uv,target=/usr/local/bin/uv \
    if [ "$TANGENT_GPU" = "1" ]; then \
        uv pip install --system --no-cache nvidia-cublas-cu12 nvidia-cudnn-cu12; \
    fi
# The wheels land under site-packages/nvidia/*/lib, which is NOT on the
# default loader path. Harmless when the dirs don't exist (CPU build).
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.11/site-packages/nvidia/cublas/lib:/usr/local/lib/python3.11/site-packages/nvidia/cudnn/lib

# Trivy flags the base image's bundled wheel/jaraco.context (CVE-2026-24049,
# CVE-2026-23949). Separate cheap layer so CVE bumps don't re-run the big
# dependency install above.
RUN --mount=from=ghcr.io/astral-sh/uv:0.9,source=/uv,target=/usr/local/bin/uv \
    uv pip install --system --no-cache --upgrade "wheel>=0.46.2" "jaraco.context>=6.1"

# Copy app code
COPY app ./app

# Run as a non-root user (uid 1000). /data is the compose bind mount; the
# HF/XDG cache envs point every model cache (pyannote, HF hub, anything
# honouring XDG) into it so downloads persist across container recreates
# and land somewhere the non-root user can write.
# Linux hosts migrating from the old root image: chown the data dir once —
#   sudo chown -R 1000:1000 ./data
# (Docker Desktop on Windows/macOS needs nothing.)
RUN useradd --create-home --uid 1000 --user-group tangent \
    && mkdir -p /data \
    && chown tangent:tangent /data /app
ENV TANGENT_DATA_DIR=/data
ENV TANGENT_HOST=0.0.0.0
ENV TANGENT_PORT=8000
ENV HF_HOME=/data/models/hf
ENV XDG_CACHE_HOME=/data/.cache
USER tangent

EXPOSE 8000

# Health check — /openapi.json is public; /v1/server/info requires bearer auth
# after setup and would fail the probe with 401 once a token exists.
# Python stdlib probe: keeps curl (and its CVE train) out of the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://localhost:8000/openapi.json', timeout=4).status==200 else 1)"]

# Run server (use uvicorn factory so the lifespan event handler runs properly)
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]

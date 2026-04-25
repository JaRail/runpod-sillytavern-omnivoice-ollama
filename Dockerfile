# Runtime stage: minimal CUDA runtime with all services
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    SILLYTAVERN_LISTEN=true \
    PATH="/app/venv/bin:$PATH"

WORKDIR /app

# Install runtime dependencies only (no build tools, no git, no gcc)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv curl ffmpeg libsm6 libxext6 jq pciutils zstd ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create Python virtual environment for isolation
RUN python3 -m venv /app/venv

# Install uv and Python dependencies in one layer
RUN /app/venv/bin/pip install --no-cache-dir --upgrade pip setuptools && \
    /app/venv/bin/pip install --no-cache-dir uv && \
    /app/venv/bin/uv pip install --system torch==2.8.0+cu128 torchaudio==2.8.0+cu128 --extra-index-url https://download.pytorch.org/whl/cu128 && \
    /app/venv/bin/uv pip install --system omnivoice-server jupyterlab faster-whisper fastapi uvicorn python-multipart

# Install Node.js runtime (for running SillyTavern)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Ollama (lightweight for serving models)
RUN curl -fsSL https://ollama.com/install.sh | sh

# Copy SillyTavern from a named build context (currently a local checkout
# with custom OmniVoice-related changes that aren't upstream yet).
# Build with:
#   docker build --build-context sillytavern=../sillytavern -t <image> .
COPY --from=sillytavern . /app/SillyTavern
#
# Once the custom changes are upstreamed, replace the COPY above with the
# block below to fetch SillyTavern's release branch directly from GitHub
# (no extra build context required). Note: this uses curl + tar so we
# don't need to install git into the runtime image.
#
# RUN curl -fsSL https://github.com/SillyTavern/SillyTavern/archive/refs/heads/release.tar.gz \
#     | tar -xz -C /app && mv /app/SillyTavern-release /app/SillyTavern
#
RUN cd /app/SillyTavern && npm ci --omit=dev

# Copy application files
COPY entrypoint.sh /app/
COPY whisper_server.py /app/
RUN sed -i 's/\r$//' /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

EXPOSE 8000 8001 5100 8888 11434

ENTRYPOINT ["/app/entrypoint.sh"]

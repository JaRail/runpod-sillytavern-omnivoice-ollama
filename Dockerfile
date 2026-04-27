# PyTorch's official runtime image: brings Python + torch + CUDA + cuDNN
# preinstalled. Skips the slowest pip install we used to do, and closes the
# cuDNN gap that the previous nvidia/cuda:12.8.0-runtime base image had.
# Python lives in /opt/conda (already on PATH).
FROM pytorch/pytorch:2.8.0-cuda12.8-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    SILLYTAVERN_LISTEN=true

# Use bash with pipefail for all RUN commands. Without this, a failed
# `curl ... | sh` (network blip, 404 on the install script) leaves the
# pipeline exit status at 0 because sh succeeded, and the installer never
# actually runs. Catches a real class of silent build bug.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /app

# System runtime dependencies. Python/pip/torch/CUDA/cuDNN come from the
# base image, so this is a pretty short list:
# - curl: ollama installer + nodesource setup
# - ffmpeg: audio decoding for faster-whisper / OmniVoice
# - libsm6 / libxext6: shared deps some audio/CV libraries pull in
# - jq: settings.json patching in entrypoint.sh
# - ca-certificates: TLS roots (usually present, kept for safety)
# - rclone: S3-compatible client used by backup.sh / restore.sh against the
#   RunPod network-volume S3 API. Apt's rclone (>=1.50) supports the
#   --endpoint-url style we need; if the version becomes a problem we can
#   switch to `curl https://rclone.org/install.sh | bash` for the latest.
#
# Not pinning apt versions: the base image is already pinned (which fixes
# the Ubuntu repo state at build time), and pinning each utility creates
# ongoing maintenance churn for marginal security benefit.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ffmpeg libsm6 libxext6 jq ca-certificates rclone \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Python dependencies via uv (much faster than pip). The base image's
# Python is a Conda env at /opt/conda; uv's --system flag tells it to
# install there directly rather than insisting on a venv.
#
# Versions pinned with stable major-version ranges. For fully reproducible
# builds, run `uv pip compile` and check in a requirements.lock.
# omnivoice-server is left unpinned: fast-moving, want latest fixes.
RUN pip install --no-cache-dir "uv>=0.4,<1" && \
    uv pip install --system \
        omnivoice-server \
        "jupyterlab>=4.0,<5" \
        "faster-whisper>=1.0,<2" \
        "fastapi>=0.110,<1" \
        "uvicorn>=0.30,<1" \
        "python-multipart>=0.0.9"

# Install Node.js runtime (for running SillyTavern).
# hadolint ignore=DL3008
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Ollama (lightweight for serving models)
RUN curl -fsSL https://ollama.com/install.sh | sh

# Copy SillyTavern from a named build context (currently a local checkout
# with custom OmniVoice-related changes that aren't upstream yet).
# Build with:
#   docker build --build-context sillytavern=../sillytavern -t <image> .
# hadolint ignore=DL3022
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
# Fail fast if the build context wasn't supplied — otherwise the npm ci
# below produces a much less obvious error.
RUN test -f /app/SillyTavern/package.json || \
    (echo "ERROR: SillyTavern source not found. Did you pass --build-context sillytavern=../sillytavern?" >&2 && exit 1)
WORKDIR /app/SillyTavern
RUN npm ci --omit=dev

# Pre-install the Speech Recognition extension into the "Install for all
# users" location so it's available out of the box. Users still have to
# enable it once in the SillyTavern Extensions panel and point STT at
# http://127.0.0.1:5100/v1 (see README).
RUN mkdir -p /app/SillyTavern/public/scripts/extensions/third-party && \
    curl -fsSL https://github.com/SillyTavern/Extension-Speech-Recognition/archive/refs/heads/main.tar.gz \
        | tar -xz -C /app/SillyTavern/public/scripts/extensions/third-party && \
    mv /app/SillyTavern/public/scripts/extensions/third-party/Extension-Speech-Recognition-main \
       /app/SillyTavern/public/scripts/extensions/third-party/Extension-Speech-Recognition

WORKDIR /app

# Copy application files
COPY entrypoint.sh /app/
COPY whisper_server.py /app/
# backup.sh / restore.sh: snapshot SillyTavern state to a RunPod
# S3-compatible network volume. Manually invoked from JupyterLab (backup),
# and called by entrypoint.sh on boot (restore) when configured.
COPY backup.sh restore.sh /app/
# System-wide Jupyter config: silences the benign 403s on /api/status that
# RunPod's edge proxy emits as health-check probes. /etc/jupyter is one of
# Jupyter's default config search paths, so no extra --config flag needed.
COPY jupyter_server_config.py /etc/jupyter/jupyter_server_config.py
# Strip CRLF (in case of Windows checkouts) and mark all shell scripts
# executable in one pass. dos2unix isn't installed; sed -i is portable.
RUN sed -i 's/\r$//' /app/entrypoint.sh /app/backup.sh /app/restore.sh && \
    chmod +x /app/entrypoint.sh /app/backup.sh /app/restore.sh

EXPOSE 8000 8001 5100 8888 11434

# Healthcheck: SillyTavern requires Basic Auth so HTTP probes get 401s.
# Use bash's /dev/tcp to verify the port is accepting connections instead.
# The 120s start period gives Ollama / OmniVoice / Whisper time to load
# their models on a cold pod before the check starts marking us unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8000' || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]

FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV SILLYTAVERN_LISTEN=true

WORKDIR /app

# 1. System Dependencies & Package Managers
# Removed the --break-system-packages flag as Ubuntu 22.04 pip doesn't require or support it
RUN apt-get update && apt-get install -y \
    curl git python3 python3-pip python3-venv \
    ffmpeg libsm6 libxext6 jq pciutils zstd \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && pip3 install uv \
    && curl -fsSL https://ollama.com/install.sh | sh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Heavy ML Dependencies (Isolated layer for caching)
RUN uv pip install --system torch==2.8.0+cu128 torchaudio==2.8.0+cu128 --extra-index-url https://download.pytorch.org/whl/cu128

# 3. Python Services (OmniVoice, JupyterLab)
RUN uv pip install --system omnivoice-server jupyterlab

# 4. SillyTavern Setup
RUN git clone https://github.com/SillyTavern/SillyTavern.git && \
    cd SillyTavern && \
    npm install

# 5. Copy local files
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

EXPOSE 8000 8001 8888 11434
ENTRYPOINT ["/app/entrypoint.sh"]
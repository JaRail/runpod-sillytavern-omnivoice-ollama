# runpod-sillytavern-omnivoice-ollama

A complete, production-ready full-stack Docker setup for running [SillyTavern](https://github.com/SillyTavern/SillyTavern) alongside the bleeding-edge [OmniVoice](https://github.com/k2-fsa/OmniVoice) TTS model and a local [Ollama](https://ollama.com/) LLM engine on a single RunPod instance.

This repository gives you a fully self-hosted, private AI voice chat environment. It hosts the persona-driven frontend (SillyTavern), the local AI "brain" (Ollama/Gemma/Llama), and the text-to-speech voice generation pipeline (OmniVoice).

## ✨ Features

* **Instant Boot:** All heavy software dependencies (CUDA, PyTorch, Node.js, Ollama, OmniVoice server, SillyTavern) are baked into the Docker image.

* **Persistent State:** Automatically symlinks SillyTavern chats, characters, extensions, and massive AI model weights to your RunPod `/workspace` volume so they survive pod restarts.

* **Modular Services:** Use RunPod environment variables to easily toggle Ollama and OmniVoice on or off to save system resources if you want to use external APIs.

* **Auto-Pull LLMs:** Specify an LLM (like `gemma4:26b`) during deployment, and the pod will automatically download it in the background while booting.

## 📂 Repository Structure

```
.
├── Dockerfile              # The optimized build instructions for the container
├── entrypoint.sh           # Handles volume mounting, config persistence, and server boot
├── whisper_server.py       # Minimal OpenAI-compatible STT server wrapping faster-whisper
├── .dockerignore           # Prevents local models/data from bloating the image build
└── .gitignore              
```

## 🚀 Deployment Guide

### Step 1: Build and Push the Docker Image

You will need to build this Docker image and push it to a container registry like Docker Hub so RunPod can access it.

1. Clone this repository to your local machine (or a build server).

2. Check out SillyTavern as a sibling directory (the Dockerfile currently consumes a local copy via a named build context so we can ship in-progress OmniVoice-related changes that aren't upstream yet):

   ```
   git clone https://github.com/SillyTavern/SillyTavern.git ../sillytavern
   ```

3. Authenticate with Docker Hub: `docker login`

4. Build the image (using your lowercase Docker Hub username). The `--build-context` flag wires the sibling SillyTavern checkout into the `COPY --from=sillytavern` line in the Dockerfile:

   ```
   docker build --build-context sillytavern=../sillytavern -t jarail/sillytavern-omnivoice-ollama:latest .
   ```

5. Push the image to your registry:

   ```
   docker push jarail/sillytavern-omnivoice-ollama:latest
   ```

### Step 2: Configure the RunPod Template

Log into your RunPod dashboard and create a **New Template** with the following settings:

* **Template Name:** SillyTavern + OmniVoice + Ollama (Full Stack)

* **Container Image:** `jarail/sillytavern-omnivoice-ollama:latest`

* **Container Disk:** `20 GB` (The image itself is large due to PyTorch, CUDA, and the OS).

* **Volume Disk:** `50 GB+` (Required to store the OmniVoice HuggingFace models, Ollama LLMs, and chat history. Recommend more if downloading large models).

* **Exposed TCP Ports:** `8000, 8001, 5100, 8888, 11434`

* **Environment Variables:**

  **Authentication (recommended to set):**

  * `ST_USER` / `ST_PASS` - Basic Auth credentials for the SillyTavern web UI. **If both are unset, a random 24-character password is generated on boot and printed to the pod logs** (Username: `admin`). Both must be set together — setting only one causes the container to refuse to start, so a half-configured login can never silently fall back to a default.

  * `JUPYTER_PASSWORD` - **Required** to enable JupyterLab. Without it, the Jupyter service is skipped (an unauthenticated Jupyter on a publicly proxied port would expose root access to `/workspace`).

  **Service toggles:**

  * `ENABLE_OLLAMA` (default `true`) - Set to `false` to disable the local LLM.

  * `ENABLE_OMNIVOICE` (default `true`) - Set to `false` to disable local TTS.

  * `ENABLE_WHISPER` (default `true`) - Set to `false` to disable local STT.

  * `ENABLE_JUPYTER` (default `true`) - Set to `false` to disable JupyterLab. Note that even when `true`, Jupyter only starts if `JUPYTER_PASSWORD` is also set.

  **Model & SillyTavern tuning:**

  * `AUTO_PULL_MODEL` - Enter an Ollama model tag (e.g., `gemma3:27b`, `llama3.1:8b`) to download automatically in the background on boot.

  * `WHISPER_MODEL` (default `base`) - faster-whisper model size to load. Options: `tiny`, `base`, `small`, `medium`, `large-v3`, `distil-large-v3`. Larger models give better accuracy at the cost of VRAM and load time.

  * `ST_CONTEXT_SIZE` - Pre-configure SillyTavern's default Context Size in tokens (e.g., `261888`).

  * `ST_AMOUNT_GEN` - Pre-configure SillyTavern's default response length in tokens (e.g., `8096`).

### Step 3: Deploy and Connect

1. Deploy a pod using your new template. (An RTX 3090, 4090, or A6000 is recommended for local voice + LLM generation).

2. Once the pod is running, click **Connect**.

3. Click **Connect to HTTP Port 8000** to open the SillyTavern Web UI. You'll be prompted for Basic Auth credentials — use whatever you set for `ST_USER` / `ST_PASS`, or check the pod logs for the auto-generated password (look for the `Generated random credentials:` banner near the top of the boot log).

4. Click **Connect to HTTP Port 8888** to open JupyterLab for remote file management (only available if you set `JUPYTER_PASSWORD`).

> **Security note:** All five exposed ports (8000, 8001, 5100, 8888, 11434) are reachable through RunPod's public proxy. Only SillyTavern (8000) and JupyterLab (8888) have authentication. The Ollama, OmniVoice, and Whisper APIs are unauthenticated and intended to be called from inside the pod — keep their proxy URLs private.

### Step 4: Configure SillyTavern inside the UI

1. **Connect the LLM:** Go to the API connections tab, set the "API Type" to **Ollama**, and set the Server URL to `http://127.0.0.1:11434`.

2. **Connect the Voice (TTS):** Go to the Extensions/Audio tab. Select **OpenAI TTS** from the Text-to-Speech dropdown menu and set the API Endpoint URL to `http://127.0.0.1:8001/v1`.

3. **Connect Speech-to-Text (STT):** The Speech Recognition extension is preinstalled in the image. Open the Extensions panel, enable **Speech Recognition**, then in the Extensions/Audio tab select **OpenAI STT** from the Speech-to-Text provider dropdown menu and set the API Endpoint URL to `http://127.0.0.1:5100/v1`.

4. Enable your microphone in SillyTavern, pick a character, and start talking!

---

## 👨‍💻 Author

**James Railton**

* GitHub: [@JaRail](https://github.com/JaRail)
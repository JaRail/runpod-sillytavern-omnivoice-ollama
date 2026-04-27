# runpod-sillytavern-omnivoice-ollama

A complete, production-ready full-stack Docker setup for running [SillyTavern](https://github.com/SillyTavern/SillyTavern) alongside the bleeding-edge [OmniVoice](https://github.com/k2-fsa/OmniVoice) TTS model and a local [Ollama](https://ollama.com/) LLM engine on a single RunPod instance.

This repository gives you a fully self-hosted, private AI voice chat environment. It hosts the persona-driven frontend (SillyTavern), the local AI "brain" (Ollama/Gemma/Llama), and the text-to-speech voice generation pipeline (OmniVoice).

## ✨ Features

* **Instant Boot:** All heavy software dependencies (CUDA, PyTorch, Node.js, Ollama, OmniVoice server, SillyTavern) are baked into the Docker image.

* **Persistent State:** Automatically symlinks SillyTavern chats, characters, extensions, and massive AI model weights to your RunPod `/workspace` volume so they survive pod restarts.

* **Modular Services:** Use RunPod environment variables to easily toggle Ollama and OmniVoice on or off to save system resources if you want to use external APIs.

* **Auto-Pull LLMs:** Specify an LLM (like `gemma4:26b`) during deployment, and the pod will automatically download it in the background while booting.

## 🧮 Hardware Requirements

Approximate VRAM footprints for each service. All three run on the same GPU by default, so add the rows together for the configuration you plan to deploy. Numbers assume the model is fully loaded into VRAM (no CPU offload).

### Whisper (STT)

faster-whisper, fp16. Set via the `WHISPER_MODEL` env var.

| Model | VRAM |
|-------|------|
| `tiny` | ~1 GB |
| `base` | ~1 GB |
| `small` | ~2 GB |
| `medium` | ~5 GB |
| `distil-large-v3` | ~6 GB |
| `large-v3` | ~10 GB |

### OmniVoice (TTS)

Roughly **3–4 GB** at fp16 with the default voice. Synthesis is short-lived and the KV cache is negligible compared to an LLM, so you can generally treat OmniVoice as a flat overhead.

### Gemma 4 (LLM via Ollama)

Two flavors are interesting here: the **31B dense** model and the **26B-A4B** mixture-of-experts model (26 B total parameters, ~4 B active per token). Weights below assume the **native QAT int4** checkpoints Google ships alongside the bf16 release — these are quantization-aware-trained, so quality is close to bf16 while the footprint matches a Q4 post-training quant. (Plain `gemma4:31b` / `gemma4:26b` in Ollama resolve to the QAT build by default; the bf16 versions roughly quadruple the weight column.) KV cache is fp16; you can roughly halve it with `OLLAMA_KV_CACHE_TYPE=q8_0` or quarter it with `q4_0` at some quality cost.

**Gemma 4 31B (dense)** — weights ≈ 17 GB

| Context | KV cache | Total VRAM |
|---------|----------|------------|
| 8k | ~3 GB | ~20 GB |
| 16k | ~6 GB | ~23 GB |
| 32k | ~12 GB | ~29 GB |
| 64k | ~24 GB | ~41 GB |
| 128k | ~48 GB | ~65 GB |
| 256k | ~96 GB | ~113 GB |

**Gemma 4 26B-A4B (MoE, ~4 B active)** — weights ≈ 13 GB

The full 26 B parameters still need to live in VRAM; only the *compute* per token is cheaper. KV cache scales with the active path, so it's noticeably lighter than the 31B at long context.

| Context | KV cache | Total VRAM |
|---------|----------|------------|
| 8k | ~2 GB | ~15 GB |
| 16k | ~4 GB | ~17 GB |
| 32k | ~8 GB | ~21 GB |
| 64k | ~16 GB | ~29 GB |
| 128k | ~32 GB | ~45 GB |
| 256k | ~64 GB | ~77 GB |

### Picking a GPU

Add Whisper + OmniVoice (typically ~5–8 GB combined with `base`/`small` Whisper) to the LLM row above:

* **24 GB (RTX 3090 / 4090):** comfortably runs 26B-A4B up to ~16k context, or 31B at 8k with a tight Whisper model. Long-context (>32k) requires KV cache quantization.
* **48 GB (A6000 / L40S):** 31B at 32k or 26B-A4B at 64k with headroom for TTS/STT.
* **80 GB (A100 / H100):** 31B at 128k or 26B-A4B at 256k.

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

  **Backup / restore (cross-region state sync):**

  These wire up `/app/backup.sh` and `/app/restore.sh` against any S3-compatible store. The intended target is a small RunPod network volume (~10 GB) used purely to shuttle SillyTavern config between pods. The volume's S3 endpoint is reachable from anywhere over the public internet, so a pod in Romania can pull state from a US-KS-2 volume — the regional pinning that prevents you from *mounting* the volume across regions does not apply to the S3 API. See RunPod's [S3 API docs](https://docs.runpod.io/storage/s3-api) for the list of S3-enabled datacenters.

  Only `st_data`, `secrets.json`, and `config.yaml` are included. Plugins and model weights are excluded — plugins reinstall from the UI, model weights would defeat the point of "small".

  * `BACKUP_S3_ENDPOINT` - The S3 API endpoint URL for your network volume's datacenter (e.g., `https://s3api-us-ks-2.runpod.io`).

  * `BACKUP_S3_REGION` - The datacenter ID, lowercased (e.g., `us-ks-2`). Required by AWS SigV4 signing.

  * `BACKUP_S3_BUCKET` - Your network volume ID (acts as the bucket name).

  * `BACKUP_S3_ACCESS_KEY` / `BACKUP_S3_SECRET_KEY` - The S3 credentials generated in the RunPod console under your user's API keys section.

  * `BACKUP_PREFIX` (default `sillytavern-backup`) - Folder within the bucket. Override if you're sharing the volume across multiple stacks.

  * `BACKUP_RESTORE_ON_BOOT` (default `false`) - When `true`, `entrypoint.sh` calls `/app/restore.sh` automatically on a fresh pod (i.e. when `/workspace/st_data` has no `default-user`). Restore failure is non-fatal — the pod boots with default seed if the snapshot is missing or unreachable.

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

## 💾 Backing up and restoring SillyTavern state

GPU availability across RunPod datacenters is uneven, so pinning yourself to one region (e.g. by mounting a network volume directly) often means waiting for capacity. The setup below sidesteps that: keep your settings on a small network volume in any datacenter, and pull them into pods running anywhere via the S3 API.

### One-time setup

1. **Create a network volume** in any S3-enabled datacenter (currently EUR-IS-1, EU-RO-1, EU-CZ-1, US-KS-2, US-CA-2). 10 GB is plenty — SillyTavern config is a few MB.

2. **Generate S3 credentials** from the RunPod console under your user settings. Note the access key, secret, and the volume ID.

3. **Set the `BACKUP_S3_*` env vars** in your pod template (see the env vars section above). Set `BACKUP_RESTORE_ON_BOOT=true` so new pods automatically pull the latest snapshot.

### Day-to-day workflow

* **Save your current state:** open JupyterLab (port 8888) → Terminal → `/app/backup.sh`. This tars your config and uploads it as `latest.tar.gz`. The previous `latest` is rotated to `previous.tar.gz` first, so you always have one snapshot of fallback in case the most recent backup captured a corrupted state.

* **Spin up a new pod:** with `BACKUP_RESTORE_ON_BOOT=true`, `entrypoint.sh` calls `/app/restore.sh` on first boot. Your characters, chats, presets, world info, API keys, and connection profiles are all there before SillyTavern's UI loads.

* **Roll back a bad backup:** `/app/restore.sh previous` re-extracts the rotated copy on top of the current `/workspace`.

* **Sync between desktop and laptop:** they're already synced — both browsers see the same server-side state on the same pod. The backup workflow only matters when you spin up a *new* pod.

### What gets backed up

`st_data/` (chats, characters, presets, world info, settings), `secrets.json` (API keys), and `config.yaml`. Plugins (`st_plugins/`) and model weights are intentionally excluded — plugins reinstall from the UI on a fresh pod, and Ollama / OmniVoice models are large enough that re-pulling them from their respective registries is faster than shuffling them through S3.

---

## 👨‍💻 Author

**James Railton**

* GitHub: [@JaRail](https://github.com/JaRail)
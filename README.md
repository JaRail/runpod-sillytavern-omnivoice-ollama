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
├── .dockerignore           # Prevents local models/data from bloating the image build
└── .gitignore              
```

## 🚀 Deployment Guide

### Step 1: Build and Push the Docker Image

You will need to build this Docker image and push it to a container registry like Docker Hub so RunPod can access it.

1. Clone this repository to your local machine (or a build server).

2. Authenticate with Docker Hub: `docker login`

3. Build the image:

   ```
   docker build -t JaRail/sillytavern-omnivoice-ollama:latest .
   ```

4. Push the image to your registry:

   ```
   docker push JaRail/sillytavern-omnivoice-ollama:latest
   ```

### Step 2: Configure the RunPod Template

Log into your RunPod dashboard and create a **New Template** with the following settings:

* **Template Name:** SillyTavern + OmniVoice + Ollama (Full Stack)

* **Container Image:** `JaRail/sillytavern-omnivoice-ollama:latest`

* **Container Disk:** `20 GB` (The image itself is large due to PyTorch, CUDA, and the OS).

* **Volume Disk:** `50 GB+` (Required to store the OmniVoice HuggingFace models, Ollama LLMs, and chat history. Recommend more if downloading large models).

* **Exposed TCP Ports:** `8000, 8001, 11434`

* **Environment Variables:** *(Optional)*

  * `ENABLE_OLLAMA` (default `true`) - Set to `false` to disable the local LLM.

  * `ENABLE_OMNIVOICE` (default `true`) - Set to `false` to disable local TTS.

  * `AUTO_PULL_MODEL` - Enter an Ollama model tag (e.g., `gemma4:26b`, `llama3`) to download automatically on boot.

### Step 3: Deploy and Connect

1. Deploy a pod using your new template. (An RTX 3090, 4090, or A6000 is recommended for local voice + LLM generation).

2. Once the pod is running, click **Connect**.

3. Click **Connect to HTTP Port 8000** to open the SillyTavern Web UI.

### Step 4: Configure SillyTavern inside the UI

1. **Connect the LLM:** Go to the API connections tab, select "Chat Completion", choose "OpenAI-Compatible", and set the URL to `http://127.0.0.1:11434/v1`.

2. **Connect the Voice:** Go to the Extensions/Audio tab. Select **OpenAI TTS** from the dropdown menu and set the API Endpoint URL to `http://127.0.0.1:8001/v1`.

3. Enable your microphone in SillyTavern, pick a character, and start talking!

---

## 👨‍💻 Author

**James Railton**
* GitHub: [@JaRail](https://github.com/JaRail)
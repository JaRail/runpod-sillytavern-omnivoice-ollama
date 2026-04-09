#!/bin/bash
set -e

echo "=== Initializing Workspace Persistence ==="
# 1. Create all necessary persistent directories
mkdir -p /workspace/st_data
mkdir -p /workspace/st_plugins
mkdir -p /workspace/omnivoice_models
export OLLAMA_MODELS="/workspace/ollama_models"
mkdir -p $OLLAMA_MODELS

# 2. Safely symlink SillyTavern persistent directories
cd /app/SillyTavern

# Handle /data
if [ ! -L "./data" ]; then
    if [ -d "./data" ] && [ ! -d "/workspace/st_data/default" ]; then
        cp -a ./data/* /workspace/st_data/ 2>/dev/null || true
    fi
    rm -rf ./data
    ln -s /workspace/st_data ./data
fi

# Handle /plugins
if [ ! -L "./plugins" ]; then
    if [ -d "./plugins" ]; then
        cp -a ./plugins/* /workspace/st_plugins/ 2>/dev/null || true
    fi
    rm -rf ./plugins
    ln -s /workspace/st_plugins ./plugins
fi

# Handle config.yaml and secrets.json files
for file in config.yaml secrets.json; do
    if [ ! -f "/workspace/$file" ] && [ -f "./$file" ]; then
        cp "./$file" "/workspace/$file"
    elif [ ! -f "/workspace/$file" ]; then
        touch "/workspace/$file"
    fi
    rm -f "./$file"
    ln -s "/workspace/$file" "./$file"
done

echo "=== Configuring SillyTavern Security ==="
# 3. Ensure SillyTavern binds to 0.0.0.0 for RunPod Proxy
if ! grep -q "listen: true" /workspace/config.yaml; then
    sed -i 's/listen: false/listen: true/g' /workspace/config.yaml 2>/dev/null || echo "listen: true" >> /workspace/config.yaml
fi

# Automatically disable whitelist mode so the RunPod web UI is accessible
if [ -f "config.yaml" ]; then
    sed -i 's/whitelistMode: true/whitelistMode: false/g' config.yaml
fi

echo "=== Booting Servers ==="

# Set default toggles to true if not specified by the user in RunPod
ENABLE_OLLAMA=${ENABLE_OLLAMA:-"true"}
ENABLE_OMNIVOICE=${ENABLE_OMNIVOICE:-"true"}

# 4. Force all ML models and caches to the persistent drive
export HF_HOME="/workspace/omnivoice_models"
export TORCH_HOME="/workspace/torch_cache"
export XDG_CACHE_HOME="/workspace/general_cache"
export OLLAMA_HOST="0.0.0.0"

PIDS_TO_WAIT=""

# Start Ollama Daemon conditionally
if [ "$ENABLE_OLLAMA" = "true" ] || [ "$ENABLE_OLLAMA" = "1" ]; then
    echo "Starting Ollama API on port 11434..."
    ollama serve &
    OLLAMA_PID=$!
    PIDS_TO_WAIT="$PIDS_TO_WAIT $OLLAMA_PID"
    
    # Wait for daemon to initialize, then auto-pull model if requested
    if [ -n "$AUTO_PULL_MODEL" ]; then
        echo "Queuing auto-pull for Ollama model: $AUTO_PULL_MODEL..."
        # Run in background to avoid blocking server boots
        (sleep 5 && ollama pull "$AUTO_PULL_MODEL" && echo "Ollama pull complete: $AUTO_PULL_MODEL") &
    fi
else
    echo "Skipping Ollama (ENABLE_OLLAMA is set to false)."
fi

# 5. Boot OmniVoice API Bridge conditionally
if [ "$ENABLE_OMNIVOICE" = "true" ] || [ "$ENABLE_OMNIVOICE" = "1" ]; then
    echo "Starting OmniVoice API on port 8001..."
    omnivoice-server --host 0.0.0.0 --port 8001 --device cuda &
    OMNI_PID=$!
    PIDS_TO_WAIT="$PIDS_TO_WAIT $OMNI_PID"
else
    echo "Skipping OmniVoice (ENABLE_OMNIVOICE is set to false)."
fi

echo "=== Verifying SillyTavern Configuration Integrity ==="
cd /app/SillyTavern

# Check if config.yaml exists. If it does, try to parse it.
if [ -f "config.yaml" ]; then
    node -e "try { require('yaml').parse(require('fs').readFileSync('config.yaml', 'utf8')) } catch (e) { process.exit(1) }" || {
        echo "Corrupted config.yaml detected (likely duplicate keys from migration). Triggering self-healing..."
        # Delete both the symlink and the physical file in the workspace to guarantee a clean slate
        rm -f /app/SillyTavern/config.yaml
        rm -f /workspace/config.yaml
    }
fi

# 6. Boot SillyTavern (Always runs)
echo "Starting SillyTavern on port 8000..."
cd /app/SillyTavern
./start.sh &
SILLY_PID=$!
PIDS_TO_WAIT="$PIDS_TO_WAIT $SILLY_PID"

echo "Systems nominal. Servers are running."

# Graceful shutdown handling for RunPod stop requests
trap "kill $PIDS_TO_WAIT" SIGINT SIGTERM

# Fix: Use 'wait -n' so if ANY server crashes (like ST out-of-memory), the whole container safely stops
wait -n $PIDS_TO_WAIT || true
kill $PIDS_TO_WAIT 2>/dev/null || true
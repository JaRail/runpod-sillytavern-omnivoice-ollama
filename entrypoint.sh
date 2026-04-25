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

# 4. Automatically disable whitelist mode so the RunPod web UI is accessible
if [ -f "config.yaml" ]; then
    sed -i 's/whitelistMode: true/whitelistMode: false/g' config.yaml

    # Enable Basic Auth and inject credentials from RunPod environment variables
    # (Using default fallbacks if the user left them blank)
    sed -i 's/basicAuthMode: false/basicAuthMode: true/g' config.yaml
    sed -i "s/basicAuthUser: .*/basicAuthUser: '${ST_USER:-admin}'/g" config.yaml
    sed -i "s/basicAuthPass: .*/basicAuthPass: '${ST_PASS:-password}'/g" config.yaml
fi


echo "=== Booting Servers ==="

# 5. Set default toggles to true if not specified by the user in RunPod
ENABLE_OLLAMA=${ENABLE_OLLAMA:-"true"}
ENABLE_OMNIVOICE=${ENABLE_OMNIVOICE:-"true"}
ENABLE_WHISPER=${ENABLE_WHISPER:-"true"}
ENABLE_JUPYTER=${ENABLE_JUPYTER:-"true"}

# 6. Force all ML models and caches to the persistent drive
export HF_HOME="/workspace/omnivoice_models"
export TORCH_HOME="/workspace/torch_cache"
export XDG_CACHE_HOME="/workspace/general_cache"
export OLLAMA_HOST="0.0.0.0"

PIDS_TO_WAIT=""

# 7. Start Ollama Daemon conditionally
if [ "$ENABLE_OLLAMA" = "true" ] || [ "$ENABLE_OLLAMA" = "1" ]; then
    echo "Starting Ollama API on port 11434..."
    export OLLAMA_KV_CACHE_TYPE=bf16
    export OLLAMA_FLASH_ATTENTION=0
    export OLLAMA_CONTEXT_LENGTH=65536
    ollama serve &
    OLLAMA_PID=$!
    PIDS_TO_WAIT="$PIDS_TO_WAIT $OLLAMA_PID"
    
    # Wait for daemon to initialize, then auto-pull model if requested
    if [ -n "$AUTO_PULL_MODEL" ]; then
        echo "Queuing auto-pull for Ollama model: $AUTO_PULL_MODEL..."
        # Run in background to avoid blocking server boots.
        # Strip Ollama's TUI progress bars (per-blob percentages, manifest spinners,
        # sha256 verification ticks) so container logs stay readable. PIPESTATUS[0]
        # preserves ollama's exit code through the grep pipe so we don't falsely
        # report success on failure.
        (
            sleep 5
            ollama pull "$AUTO_PULL_MODEL" 2>&1 | \
                grep --line-buffered -avE '(pulling [0-9a-f]{12}:|pulling manifest|verifying sha256 digest|writing manifest)'
            rc=${PIPESTATUS[0]}
            if [ "$rc" -eq 0 ]; then
                echo "Ollama pull complete: $AUTO_PULL_MODEL"
            else
                echo "Ollama pull FAILED (exit $rc): $AUTO_PULL_MODEL"
            fi
        ) &
    fi
else
    echo "Skipping Ollama (ENABLE_OLLAMA is set to false)."
fi

# 8. Boot OmniVoice API Bridge conditionally via cmd line args on port 8001
if [ "$ENABLE_OMNIVOICE" = "true" ] || [ "$ENABLE_OMNIVOICE" = "1" ]; then
    echo "Starting OmniVoice API on port 8001..."
    OMNIVOICE_PORT=8001 omnivoice-server --host 0.0.0.0 --device cuda &
    OMNI_PID=$!
    PIDS_TO_WAIT="$PIDS_TO_WAIT $OMNI_PID"
else
    echo "Skipping OmniVoice (ENABLE_OMNIVOICE is set to false)."
fi

# 8.5. Boot Whisper API conditionally on port 5100
if [ "$ENABLE_WHISPER" = "true" ] || [ "$ENABLE_WHISPER" = "1" ]; then
    echo "Starting Whisper API on port 5100..."
    export WHISPER_PORT=5100
    export WHISPER_HOST="0.0.0.0"
    python3 /app/whisper_server.py &
    WHISPER_PID=$!
    PIDS_TO_WAIT="$PIDS_TO_WAIT $WHISPER_PID"
else
    echo "Skipping Whisper (ENABLE_WHISPER is set to false)."
fi

# 9. Boot JupyterLab conditionally
if [ "$ENABLE_JUPYTER" = "true" ] || [ "$ENABLE_JUPYTER" = "1" ]; then
    echo "Starting JupyterLab on port 8888..."
    # Use modern ServerApp.* options (NotebookApp.* is deprecated in jupyter_server 2.0).
    # allow_origin / allow_remote_access / disable_check_xsrf are required so the
    # RunPod proxy (https://<pod>-8888.proxy.runpod.net) isn't blocked as cross-origin.
    jupyter lab --allow-root --ip=0.0.0.0 --port=8888 --no-browser \
        --ServerApp.token='' --ServerApp.password='' \
        --ServerApp.allow_origin='*' \
        --ServerApp.allow_remote_access=True \
        --ServerApp.disable_check_xsrf=True \
        --notebook-dir=/workspace &
    JUPYTER_PID=$!
    PIDS_TO_WAIT="$PIDS_TO_WAIT $JUPYTER_PID"
else
    echo "Skipping JupyterLab (ENABLE_JUPYTER is set to false)."
fi

echo "=== Verifying SillyTavern Configuration Integrity ==="
cd /app/SillyTavern

# 10. Check if config.yaml exists. If it does, try to parse it.
if [ -f "config.yaml" ]; then
    node -e "try { require('yaml').parse(require('fs').readFileSync('config.yaml', 'utf8')) } catch (e) { process.exit(1) }" || {
        echo "Corrupted config.yaml detected (likely duplicate keys from migration). Triggering self-healing..."
        # Delete both the symlink and the physical file in the workspace to guarantee a clean slate
        rm -f /app/SillyTavern/config.yaml
        rm -f /workspace/config.yaml
    }
fi

# 10.5. Pre-configure SillyTavern Settings
ST_USER_DIR="/workspace/st_data/default-user"
ST_SETTINGS="$ST_USER_DIR/settings.json"

echo "Injecting default SillyTavern settings..."
mkdir -p "$ST_USER_DIR"

if [ ! -f "$ST_SETTINGS" ]; then
    if [ -f "/app/SillyTavern/default/content/settings.json" ]; then
        cp /app/SillyTavern/default/content/settings.json "$ST_SETTINGS"
    elif [ -f "/app/SillyTavern/default/settings.json" ]; then
        cp /app/SillyTavern/default/settings.json "$ST_SETTINGS"
    else
        echo "Warning: Base settings.json template not found. Skipping auto-config to prevent UI corruption."
        ST_SKIP_CONFIG="true"
    fi
fi

if [ "$ST_SKIP_CONFIG" != "true" ]; then
    JQ_FILTER="."
    # if [ "$ENABLE_OLLAMA" = "true" ] || [ "$ENABLE_OLLAMA" = "1" ]; then
    #     JQ_FILTER="$JQ_FILTER | .main_api=\"ollama\" | .api_server=\"http://127.0.0.1:11434\" | .ollama_settings = (.ollama_settings // {}) | .ollama_settings.server=\"http://127.0.0.1:11434\""
    # fi
    if [ -n "$ST_MAX_CONTEXT" ]; then
        JQ_FILTER="$JQ_FILTER | .max_context=($ST_MAX_CONTEXT | tonumber)"
    fi
    if [ -n "$ST_AMOUNT_GEN" ]; then
        JQ_FILTER="$JQ_FILTER | .amount_gen=($ST_AMOUNT_GEN | tonumber)"
    fi
    # if [ "$ENABLE_OMNIVOICE" = "true" ] || [ "$ENABLE_OMNIVOICE" = "1" ]; then
    #     JQ_FILTER="$JQ_FILTER | .tts_provider=\"openai\" | .openai_tts_url=\"http://127.0.0.1:8001/v1\""
    # fi
    # if [ "$ENABLE_WHISPER" = "true" ] || [ "$ENABLE_WHISPER" = "1" ]; then
    #     JQ_FILTER="$JQ_FILTER | .stt_provider=\"openai\" | .openai_stt_url=\"http://127.0.0.1:5100/v1\""
    # fi

    tmp=$(mktemp)
    if jq "$JQ_FILTER" "$ST_SETTINGS" > "$tmp"; then
        mv "$tmp" "$ST_SETTINGS"
    else
        echo "Failed to inject SillyTavern settings (jq error)."
    fi
fi

# 11. Boot SillyTavern (Always runs)
echo "Starting SillyTavern on port 8000..."
cd /app/SillyTavern
node server.js &
SILLY_PID=$!
PIDS_TO_WAIT="$PIDS_TO_WAIT $SILLY_PID"

echo "Systems nominal. Servers are running."

# 12. Graceful shutdown handling for RunPod stop requests
trap "kill $PIDS_TO_WAIT" SIGINT SIGTERM

# 13. Use 'wait -n' so if ANY server crashes (like ST out-of-memory), the whole container safely stops
wait -n $PIDS_TO_WAIT || true
kill $PIDS_TO_WAIT 2>/dev/null || true
#!/bin/bash
# -e: exit on error. -o pipefail: a failed command in a pipeline fails the whole pipe.
# (Skipping -u: too many of our env vars are intentionally optional and the
# extra `${VAR:-}` boilerplate isn't worth the noise.)
set -eo pipefail

# 0. Install signal handling early, before any service starts. PIDS_TO_WAIT
# is a bash array appended to as services launch; cleanup is a no-op if
# it's still empty when a signal arrives. (Array form keeps PIDs as
# distinct args to kill/wait — important for shellcheck SC2086 too.)
PIDS_TO_WAIT=()
cleanup() {
    if [ ${#PIDS_TO_WAIT[@]} -gt 0 ]; then
        kill "${PIDS_TO_WAIT[@]}" 2>/dev/null || true
    fi
}
trap cleanup SIGINT SIGTERM

echo "=== Initializing Workspace Persistence ==="
# 1. Create all necessary persistent directories
mkdir -p /workspace/st_data
mkdir -p /workspace/st_plugins
mkdir -p /workspace/omnivoice_models
export OLLAMA_MODELS="/workspace/ollama_models"
mkdir -p "$OLLAMA_MODELS"

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

# Handle /plugins. Mirror the data behaviour: only seed from the image if
# the workspace directory is empty. Otherwise we'd clobber user-installed
# plugins every time the container restarts after an image update.
if [ ! -L "./plugins" ]; then
    if [ -d "./plugins" ] && [ -z "$(ls -A /workspace/st_plugins 2>/dev/null)" ]; then
        cp -a ./plugins/* /workspace/st_plugins/ 2>/dev/null || true
    fi
    rm -rf ./plugins
    ln -s /workspace/st_plugins ./plugins
fi

# Handle config.yaml and secrets.json files.
#
# First-run logic: if the workspace doesn't have the file yet, seed it from a
# template shipped in the SillyTavern source (preferring *.example, which is
# what ST normally ships). If no template exists, we leave the workspace path
# absent and just create the symlink — SillyTavern will create the real file
# at the symlink target on first write. We do NOT touch an empty file: an
# empty config.yaml prevents SillyTavern from regenerating its defaults.
for file in config.yaml secrets.json; do
    if [ ! -f "/workspace/$file" ]; then
        if [ -f "./$file.example" ]; then
            cp "./$file.example" "/workspace/$file"
        elif [ -f "./$file" ]; then
            cp "./$file" "/workspace/$file"
        fi
        # else: leave /workspace/$file absent — symlink will be a dangling
        # target, and SillyTavern will create the file on first write.
    fi
    rm -f "./$file"
    ln -s "/workspace/$file" "./$file"
done

echo "=== Configuring SillyTavern Security ==="
# 3. Ensure SillyTavern binds to 0.0.0.0 for RunPod Proxy.
# Only edit config.yaml if it actually exists (it may not on a fresh install
# where SillyTavern hasn't generated it yet — that's handled by the
# SILLYTAVERN_LISTEN env var baked into the Dockerfile).
if [ -f /workspace/config.yaml ]; then
    if grep -q "^listen:" /workspace/config.yaml; then
        sed -i 's/^listen: .*/listen: true/' /workspace/config.yaml
    else
        echo "listen: true" >> /workspace/config.yaml
    fi
fi

# 4. Automatically disable whitelist mode and configure Basic Auth.
# Defaulting to admin/password is unsafe on a publicly proxied port, so:
#   - if neither ST_USER nor ST_PASS is set, generate a random password and
#     print it to logs so the user can grab it from RunPod's log viewer;
#   - if only one half is provided, refuse to start rather than silently
#     fall back to a weak default.
if [ -z "$ST_USER" ] && [ -z "$ST_PASS" ]; then
    ST_USER="admin"
    # Generate via python to avoid bash pipefail+SIGPIPE quirks with `head -c`.
    ST_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))")
    echo "===================================================================="
    echo "ST_USER / ST_PASS were not set. Generated random credentials:"
    echo "  Username: $ST_USER"
    echo "  Password: $ST_PASS"
    echo "Set ST_USER and ST_PASS env vars in RunPod to use your own values."
    echo "===================================================================="
elif [ -z "$ST_USER" ] || [ -z "$ST_PASS" ]; then
    echo "ERROR: ST_USER and ST_PASS must be set together (or both unset to auto-generate)." >&2
    echo "  Refusing to start with a half-configured login." >&2
    exit 1
fi

if [ -f "config.yaml" ]; then
    sed -i 's/whitelistMode: true/whitelistMode: false/g' config.yaml

    # Enable Basic Auth and inject credentials.
    sed -i 's/basicAuthMode: false/basicAuthMode: true/g' config.yaml
    sed -i "s/basicAuthUser: .*/basicAuthUser: '${ST_USER}'/g" config.yaml
    sed -i "s/basicAuthPass: .*/basicAuthPass: '${ST_PASS}'/g" config.yaml

    # Disable prompt/LLM payload logging to prevent RunPod log spam
    sed -i 's/logPrompts: true/logPrompts: false/g' config.yaml
    sed -i 's/minLogLevel: 0/minLogLevel: 1/g' config.yaml
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

# 7. Start Ollama Daemon conditionally
if [ "$ENABLE_OLLAMA" = "true" ] || [ "$ENABLE_OLLAMA" = "1" ]; then
    echo "Starting Ollama API on port 11434..."
    export OLLAMA_KV_CACHE_TYPE=bf16
    export OLLAMA_FLASH_ATTENTION=0
    export OLLAMA_CONTEXT_LENGTH=65536
    ollama serve &
    OLLAMA_PID=$!
    PIDS_TO_WAIT+=("$OLLAMA_PID")

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
    OMNIVOICE_PORT=8001 omnivoice-server --host 0.0.0.0 --device cuda --log-level warning &
    OMNI_PID=$!
    PIDS_TO_WAIT+=("$OMNI_PID")
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
    PIDS_TO_WAIT+=("$WHISPER_PID")
else
    echo "Skipping Whisper (ENABLE_WHISPER is set to false)."
fi

# 9. Boot JupyterLab conditionally.
# JupyterLab's port is publicly proxied by RunPod, so we MUST require auth.
# If JUPYTER_PASSWORD isn't set, we skip Jupyter entirely rather than expose
# an unauthenticated root shell on /workspace.
if [ "$ENABLE_JUPYTER" = "true" ] || [ "$ENABLE_JUPYTER" = "1" ]; then
    if [ -z "$JUPYTER_PASSWORD" ]; then
        echo "Skipping JupyterLab: JUPYTER_PASSWORD not set."
        echo "  (Refusing to expose an unauthenticated Jupyter on a public proxy.)"
    else
        echo "Starting JupyterLab on port 8888..."
        # Hash the password with jupyter_server's helper so the plaintext never
        # touches the process arg list. Read it from the env inside python to
        # keep it off the `python -c` command line too.
        JUPYTER_PW_HASH=$(python3 -c "import os; from jupyter_server.auth import passwd; print(passwd(os.environ['JUPYTER_PASSWORD']))")
        # Use modern ServerApp.* options (NotebookApp.* is deprecated in jupyter_server 2.0).
        # allow_origin / allow_remote_access / disable_check_xsrf are required so the
        # RunPod proxy (https://<pod>-8888.proxy.runpod.net) isn't blocked as cross-origin.
        # A logging filter at /etc/jupyter/jupyter_server_config.py mutes RunPod's
        # /api/status health-check 403s — see that file for the rationale.
        jupyter lab --allow-root --ip=0.0.0.0 --port=8888 --no-browser \
            --ServerApp.token='' \
            --ServerApp.password="$JUPYTER_PW_HASH" \
            --ServerApp.allow_origin='*' \
            --ServerApp.allow_remote_access=True \
            --ServerApp.disable_check_xsrf=True \
            --notebook-dir=/workspace &
        JUPYTER_PID=$!
        PIDS_TO_WAIT+=("$JUPYTER_PID")
    fi
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

    if [ -n "$ST_CONTEXT_SIZE" ]; then
        JQ_FILTER="$JQ_FILTER | .max_context=($ST_CONTEXT_SIZE | tonumber)"
    fi
    if [ -n "$ST_AMOUNT_GEN" ]; then
        JQ_FILTER="$JQ_FILTER | .amount_gen=($ST_AMOUNT_GEN | tonumber)"
    fi

    # NOTE: Auto-wiring SillyTavern's API/TTS/STT providers from the
    # entrypoint is intentionally NOT done. SillyTavern's settings.json
    # schema drifts between releases, and writing keys that the current
    # version doesn't recognize tends to corrupt the UI on load. Users
    # configure these once via the SillyTavern UI; the relevant URLs are
    # documented in the README.

    tmp=$(mktemp)
    if jq "$JQ_FILTER" "$ST_SETTINGS" > "$tmp"; then
        mv "$tmp" "$ST_SETTINGS"
    else
        echo "Failed to inject SillyTavern settings (jq error)."
        rm -f "$tmp"
    fi
fi

# 11. Boot SillyTavern (Always runs)
echo "Starting SillyTavern on port 8000..."
cd /app/SillyTavern
node server.js &
SILLY_PID=$!
PIDS_TO_WAIT+=("$SILLY_PID")

echo "Systems nominal. Servers are running."

# 12. Use 'wait -n' so if ANY server crashes (e.g. ST out-of-memory) the
# whole container safely stops. The SIGINT/SIGTERM trap was already set
# at the top of this script — see the cleanup() function.
wait -n "${PIDS_TO_WAIT[@]}" || true
cleanup

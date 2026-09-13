#!/bin/bash
# vast.ai PROVISIONING_SCRIPT — runs once after Supervisor starts (marker: /.provisioning_complete).
# Idempotent by design; safe to re-run manually.
#
# Required env (set in the vast.ai template):
#   MUSIC_API_KEY   — bearer key for the inference server (also used by the UI)
#   HF_TOKEN        — only if the HF repo ever requires auth (currently public)
# Optional env:
#   DEPLOY_REPO     — git URL of THIS repo (default below). Must be reachable from the instance.
#   DEPLOY_REF      — branch/tag/commit to check out (default: main)
#   MUSIC_UI_REPO   — upstream UI repo (default pinned below)
#   MUSIC_UI_REF    — UI commit (default pinned below)
#   OFFLOAD         — "1" enables CPU offload mode (~22GB VRAM, slower)
set -euo pipefail

: "${MUSIC_API_KEY:?MUSIC_API_KEY must be set in the vast.ai template env}"

DEPLOY_REPO="${DEPLOY_REPO:-https://github.com/derekhsu/minimax-music-gen-vastai.git}"
DEPLOY_REF="${DEPLOY_REF:-main}"
MUSIC_UI_REPO="${MUSIC_UI_REPO:-https://github.com/adambenhassen/minimax-music-ui.git}"
MUSIC_UI_REF="${MUSIC_UI_REF:-1ef679772dc8c41955b6636189e5d66c291b1d66}"
MODEL_REPO="MiniMaxAI/MiniMax-Music3"
MODEL_REV="fbdf52fbaaca799592917417eb05f1899f1255ec"

export HF_HOME="${HF_HOME:-/workspace/hf}"
export DATA_DIRECTORY="${DATA_DIRECTORY:-/workspace}"

log() { echo "[onstart] $*"; }
. /venv/main/bin/activate

# Node via nvm (not on PATH in provisioning context)
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# --- 1. Fetch this repo (vendored inference server + scripts) -----------------
if [ ! -d /workspace/deploy/.git ]; then
    log "cloning $DEPLOY_REPO @ $DEPLOY_REF"
    git clone --depth 1 --branch "$DEPLOY_REF" "$DEPLOY_REPO" /workspace/deploy
else
    log "deploy repo already present, fetching $DEPLOY_REF"
    git -C /workspace/deploy fetch --depth 1 origin "$DEPLOY_REF" || true
    git -C /workspace/deploy checkout FETCH_HEAD || true
fi

# --- 2. Python deps (torch comes from the image; do not reinstall) ------------
log "installing python deps"
uv pip install --no-cache-dir -r /workspace/deploy/inference/requirements.txt
python -c "import torch, diffusers; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), '| diffusers', diffusers.__version__)"

# --- 3. Model weights — diffusers pipeline needs only these subfolders --------
# Full repo is 57.4GB; the modular pipeline uses ~28.5GB (skips qwen_7B/ training
# checkpoints and root .pth files used by sgl-omni).
MODEL_DIR="$HF_HOME/hub/models--MiniMaxAI--MiniMax-Music3"
if [ ! -f /workspace/.weights_done ]; then
    log "downloading model weights (~28.5GB, rev ${MODEL_REV:0:7})"
    hf download "$MODEL_REPO" --revision "$MODEL_REV" \
        --include "condition_encoder/*" "language_model/*" "rvq_depth_decoder/*" \
                  "scheduler/*" "tokenizer/*" "transformer/*" "vocoder/*" \
                  "modular_model_index.json" "config.json"
    touch /workspace/.weights_done
else
    log "weights already downloaded"
fi

# --- 4. Web UI (build from pinned source; no GPU needed) -----------------------
if [ ! -d /workspace/minimax-music-ui/.git ]; then
    log "cloning UI @ ${MUSIC_UI_REF:0:7}"
    git clone "$MUSIC_UI_REPO" /workspace/minimax-music-ui
    git -C /workspace/minimax-music-ui checkout "$MUSIC_UI_REF"
fi
if [ ! -d /workspace/minimax-music-ui/web/dist ]; then
    log "building UI"
    cd /workspace/minimax-music-ui
    npm install
    npm run build
    cd /
fi

# --- 5. Supervisor apps --------------------------------------------------------
OFFLOAD_FLAG=""
[ "${OFFLOAD:-0}" = "1" ] && OFFLOAD_FLAG="--offload"

cat > /opt/supervisor-scripts/music-inference.sh << EOF
#!/bin/bash
utils=/opt/supervisor-scripts/utils
. "\${utils}/logging.sh"
. "\${utils}/environment.sh"
source /venv/main/bin/activate
export HF_HOME="$HF_HOME"
exec python /workspace/deploy/inference/server.py \\
    --host 127.0.0.1 --port 7862 --api-key "$MUSIC_API_KEY" $OFFLOAD_FLAG
EOF
chmod +x /opt/supervisor-scripts/music-inference.sh

cat > /opt/supervisor-scripts/music-ui.sh << EOF
#!/bin/bash
utils=/opt/supervisor-scripts/utils
. "\${utils}/logging.sh"
. "\${utils}/environment.sh"
export NVM_DIR="/opt/nvm"
. "\$NVM_DIR/nvm.sh"
export MUSIC_API="http://127.0.0.1:7862"
export MUSIC_API_KEY="$MUSIC_API_KEY"
export DATA_DIR="/workspace/ui-data"
export STATIC_DIR="/workspace/minimax-music-ui/web/dist"
export PORT=18787
cd /workspace/minimax-music-ui
exec node server/dist/index.js
EOF

for app in music-inference music-ui; do
    cat > "/etc/supervisor/conf.d/$app.conf" << EOF
[program:$app]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/$app.sh
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF
done


supervisorctl reread && supervisorctl update
log "done — inference on 127.0.0.1:7862, UI on 127.0.0.1:18787 (external via Caddy :8787)"

# --- 6. Portal config --------------------------------------------------------
# PORTAL_CONFIG contains '|' which vast.ai's --env parsing truncates, so we set
# it here instead of relying on the template env. caddy_config_manager.py
# regenerates /etc/portal.yaml from PORTAL_CONFIG when the file is absent.
PORTAL_LINE='PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8787:18787:/:Music UI"'
grep -q '^PORTAL_CONFIG=' /etc/environment || echo "$PORTAL_LINE" >> /etc/environment
if ! grep -q 'Music UI' /etc/portal.yaml 2>/dev/null; then
    rm -f /etc/portal.yaml
    supervisorctl restart caddy || true
fi

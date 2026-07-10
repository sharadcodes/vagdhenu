#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Vāgdhenu — one-shot deploy script
#  Clones the repo, injects the FastAPI REST API + Docker setup, builds & launches.
#
#  USAGE:
#    bash deploy.sh                          # deploys to this machine (localhost)
#    bash deploy.sh user@host                # deploys over SSH (key-based auth)
#    bash deploy.sh user@host -i key.pem     # deploys over SSH with a specific key
#
#  PREREQS on the target:
#    - NVIDIA GPU + driver ≥ 525 (CUDA 12.1 compatible)
#    - Docker + Docker Compose v2 + nvidia-container-toolkit
#    - (if remote) SSH key-based auth for the target user
#
#  After deploy:
#    Web UI:  http://<host>:8000
#    API:     POST http://<host>:8000/api/chant   (JSON → MP3 bytes)
#             POST http://<host>:8000/api/chant/json  (JSON → JSON+base64)
#             GET  http://<host>:8000/api/meters
#             GET  http://<host>:8000/api/health
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── parse args ────────────────────────────────────────────────────────────────
SSH_TARGET=""
SSH_KEY=""
REMOTE=""
for arg in "$@"; do
  case "$arg" in
    -i) shift; SSH_KEY="-i $1" ;;
    *)  SSH_TARGET="$arg" ;;
  esac
done
if [ -n "$SSH_TARGET" ]; then
  REMOTE="ssh $SSH_KEY -o StrictHostKeyChecking=no $SSH_TARGET"
fi

# ── paths (this script lives in the repo root alongside api/, Dockerfile, …) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/prathoshap/vagdhenu.git"
DEST="~/vagdhenu"

run() { if [ -n "$REMOTE" ]; then $REMOTE "$1"; else eval "$1"; fi; }
copy() {
  local src="$1" dst="$2"
  if [ -n "$REMOTE" ]; then
    scp $SSH_KEY -o StrictHostKeyChecking=no -r "$src" "$SSH_TARGET:$dst"
  else
    cp -r "$src" "$dst"
  fi
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Vāgdhenu — Sanskrit Chant TTS · one-shot deploy             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "Target: ${SSH_TARGET:-localhost}"
echo ""

# ── 1. clone / update the repo ────────────────────────────────────────────────
echo "[1/6] Cloning/updating repo…"
run "if [ -d $DEST/.git ]; then cd $DEST && git pull --ff-only || true; else rm -rf $DEST && git clone --depth 1 $REPO_URL $DEST; fi"

# ── 2. copy our API + Docker files into the repo ──────────────────────────────
echo "[2/6] Injecting API + Docker files…"
# The api/, Dockerfile, docker-compose.yml, etc. live alongside this script.
# Copy them into the cloned repo (overlays our additions on the upstream code).
# When deploying locally (no SSH), if the script IS inside the repo dir, skip.
_in_repo=false
if [ -z "$REMOTE" ]; then
  real_script="$(cd "$SCRIPT_DIR" && pwd)"
  real_dest="$(eval cd "$DEST" && pwd 2>/dev/null)" || real_dest=""
  if [ "$real_script" = "$real_dest" ]; then _in_repo=true; fi
fi
if [ "$_in_repo" = true ]; then
  echo "  (script is inside the repo — files already in place)"
else
  for f in api Dockerfile docker-compose.yml .dockerignore pyproject.toml uv.lock deploy.sh .gitattributes; do
    if [ -e "$SCRIPT_DIR/$f" ]; then copy "$SCRIPT_DIR/$f" "$DEST/"; fi
  done
fi

# ── 3. check GPU + Docker on target ───────────────────────────────────────────
echo "[3/6] Checking GPU + Docker…"
run "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1 || { echo 'ERROR: no GPU detected'; exit 1; }"
run "docker --version 2>&1 || { echo 'ERROR: docker not installed'; exit 1; }"
run "docker compose version 2>&1 || { echo 'ERROR: docker compose v2 not installed'; exit 1; }"
run "docker run --rm --gpus all nvidia/cuda:12.1.0-runtime-ubuntu22.04 nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | tail -1 || { echo 'ERROR: nvidia-container-toolkit not configured'; exit 1; }"

# ── 4. build the Docker image ─────────────────────────────────────────────────
echo "[4/6] Building Docker image (this takes ~5-10 min on first run)…"
run "cd $DEST && docker compose build"

# ── 5. launch ─────────────────────────────────────────────────────────────────
echo "[5/6] Launching container…"
run "cd $DEST && docker compose down 2>/dev/null || true && docker compose up -d"

# ── 6. wait for health ────────────────────────────────────────────────────────
echo "[6/6] Waiting for the model to warm up (60-120s)…"
run "for i in \$(seq 1 60); do
  status=\$(docker inspect --format='{{.State.Health.Status}}' vagdhenu-api 2>/dev/null || echo 'starting')
  if [ \"\$status\" = 'healthy' ]; then echo '✓ healthy'; break; fi
  printf '.'
  sleep 5
done
echo ''
docker compose -f $DEST/docker-compose.yml ps
"

# ── done ──────────────────────────────────────────────────────────────────────
HOST="${SSH_TARGET#*@}"
HOST="${HOST%% *}"
if [ -z "$SSH_TARGET" ]; then HOST="localhost"; fi
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✓ Deploy complete                                           ║"
echo "║                                                              ║"
echo "║  Web UI:   http://$HOST:8000                                 ║"
echo "║  Health:   GET  http://$HOST:8000/api/health                 ║"
echo "║  Meters:   GET  http://$HOST:8000/api/meters                 ║"
echo "║  Chant:    POST http://$HOST:8000/api/chant  (→ MP3)         ║"
echo "║  Chant:    POST http://$HOST:8000/api/chant/json (→ JSON)    ║"
echo "║                                                              ║"
echo "║  Logs:     docker compose -f ~/vagdhenu/docker-compose.yml   ║"
echo "║            logs -f                                           ║"
echo "║  Stop:     docker compose -f ~/vagdhenu/docker-compose.yml   ║"
echo "║            down                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

#!/usr/bin/env bash
# 00-baseline.sh — exact OpenClaw 2.0 (v2026.8.1) in Docker, before any Kubernetes exists.
#
# Uses OpenClaw's own maintained Docker setup from a source checkout at the tag, with the
# prebuilt -browser image. Everything it writes lives under .runtime/ in this lab directory:
# no $HOME mount, no SSH keys, no personal browser profile.
#
#   ./scripts/00-baseline.sh            # start (idempotent)
#   ./scripts/00-baseline.sh down       # stop and remove the compose project
#   OPENCLAW_SANDBOX=1 ./scripts/00-baseline.sh   # also enable OpenClaw's own Docker tool sandbox
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require docker; require git; require python3; check_docker

SRC="$RUNTIME/openclaw-src"
export OPENCLAW_CONFIG_DIR="$RUNTIME/openclaw/config"
export OPENCLAW_WORKSPACE_DIR="$RUNTIME/openclaw/workspace"
export OPENCLAW_AUTH_PROFILE_SECRET_DIR="$RUNTIME/openclaw/auth"
export OPENCLAW_EXTRA_MOUNTS="$RUNTIME/openclaw/cache:/home/node/.cache/openclaw"
export COMPOSE_PROJECT_NAME="$BASELINE_PROJECT"
export OPENCLAW_SKIP_ONBOARDING=1
export OPENCLAW_GATEWAY_BIND=lan          # the container port is published to 127.0.0.1 only
export OPENCLAW_DISABLE_BONJOUR=1
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_BASELINE_PORT:-18789}"

compose() { docker compose --project-directory "$SRC" -f "$SRC/docker-compose.yml" "$@"; }

if [[ "${1:-}" == "down" ]]; then
  [[ -d "$SRC" ]] && compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$BASELINE_CONTAINER" >/dev/null 2>&1 || true
  ok "baseline stopped (state kept under $RUNTIME/openclaw; rm -rf it to start clean)"
  exit 0
fi
require_secrets

step "OpenClaw source at v${OPENCLAW_VERSION} (for its maintained Docker setup)"
if [[ ! -d "$SRC/.git" ]]; then
  git clone -q --depth 1 --branch "v${OPENCLAW_VERSION}" https://github.com/openclaw/openclaw.git "$SRC"
fi
log "$(git -C "$SRC" describe --tags --always)"

step "workspace seed"
mkdir -p "$OPENCLAW_CONFIG_DIR" "$OPENCLAW_WORKSPACE_DIR/skills/lab-inspector" "$OPENCLAW_AUTH_PROFILE_SECRET_DIR" "$RUNTIME/openclaw/cache" "$CAPTURES"
cp "$LAB_DIR/openclaw/workspace/AGENTS.md" "$OPENCLAW_WORKSPACE_DIR/AGENTS.md"
cp "$LAB_DIR/openclaw/workspace/skills/lab-inspector/SKILL.md" "$OPENCLAW_WORKSPACE_DIR/skills/lab-inspector/SKILL.md"
[[ -f "$OPENCLAW_WORKSPACE_DIR/MEMORY.md" ]] || cp "$LAB_DIR/openclaw/workspace/MEMORY.md" "$OPENCLAW_WORKSPACE_DIR/MEMORY.md"
if [[ ! -f "$RUNTIME/openclaw/gateway-token" ]]; then
  umask 077; python3 -c 'import secrets; print(secrets.token_hex(32))' > "$RUNTIME/openclaw/gateway-token"; umask 022
fi
OPENCLAW_GATEWAY_TOKEN="$(<"$RUNTIME/openclaw/gateway-token")"
export OPENCLAW_GATEWAY_TOKEN

step "image ${OPENCLAW_IMAGE%%@*}"
docker pull -q "$OPENCLAW_IMAGE" >/dev/null
export OPENCLAW_IMAGE
# Compose reads these from .env; setup.sh keeps them in sync on later runs.
python3 - "$SRC/.env" <<'PY'
import os, sys
keys = ["ANTHROPIC_API_KEY", "OPENCLAW_IMAGE", "OPENCLAW_CONFIG_DIR", "OPENCLAW_WORKSPACE_DIR",
        "OPENCLAW_AUTH_PROFILE_SECRET_DIR", "OPENCLAW_GATEWAY_TOKEN", "OPENCLAW_GATEWAY_PORT",
        "OPENCLAW_GATEWAY_BIND", "OPENCLAW_DISABLE_BONJOUR", "OPENCLAW_EXTRA_MOUNTS", "COMPOSE_PROJECT_NAME"]
with open(sys.argv[1], "w") as f:
    f.write("".join(f"{k}={os.environ[k]}\n" for k in keys))
os.chmod(sys.argv[1], 0o600)
PY

cli() { compose run -T --rm --no-deps --entrypoint node openclaw-gateway dist/index.js "$@"; }

step "non-interactive onboarding (API key by env reference, gateway token auth)"
if [[ ! -f "$OPENCLAW_CONFIG_DIR/openclaw.json" ]]; then
  cli onboard --non-interactive --accept-risk --mode local --auth-choice apiKey \
    --secret-input-mode ref --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --skip-health --skip-channels --skip-skills --skip-search --skip-hooks --skip-ui --skip-bootstrap \
    --no-install-daemon --suppress-gateway-token-output >/dev/null
fi
# Lab defaults: full tool profile, exec on the gateway host, no exec prompts (the approval
# test switches them on deliberately), headless managed Chromium.
cli config set --batch-json "[\
{\"path\":\"agents.defaults.model.primary\",\"value\":\"${MODEL_PROVIDER}/${MODEL_NAME}\"},\
{\"path\":\"tools.profile\",\"value\":\"full\"},\
{\"path\":\"tools.exec.host\",\"value\":\"gateway\"},\
{\"path\":\"tools.exec.security\",\"value\":\"full\"},\
{\"path\":\"tools.exec.ask\",\"value\":\"off\"},\
{\"path\":\"browser.headless\",\"value\":true},\
{\"path\":\"browser.noSandbox\",\"value\":true},\
{\"path\":\"browser.defaultProfile\",\"value\":\"openclaw\"}]" >/dev/null

step "OpenClaw's maintained Docker setup (scripts/docker/setup.sh)"
bash "$SRC/scripts/docker/setup.sh" >"$RUNTIME/openclaw/setup.log" 2>&1 || { tail -30 "$RUNTIME/openclaw/setup.log" >&2; die "setup.sh failed"; }
# Upstream publishes the gateway on 0.0.0.0. Re-create it bound to loopback only.
cat > "$SRC/docker-compose.lab.yml" <<EOF
services:
  openclaw-gateway:
    ports: !override
      - "127.0.0.1:${OPENCLAW_GATEWAY_PORT}:18789"
EOF
overlays=(-f "$SRC/docker-compose.extra.yml")
[[ -f "$SRC/docker-compose.sandbox.yml" ]] && overlays+=(-f "$SRC/docker-compose.sandbox.yml")
compose "${overlays[@]}" -f "$SRC/docker-compose.lab.yml" up -d openclaw-gateway >/dev/null 2>&1
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz" >/dev/null || die "gateway did not answer on :${OPENCLAW_GATEWAY_PORT}"
docker exec "$BASELINE_CONTAINER" node dist/index.js --version | tee "$CAPTURES/openclaw-version.txt"
docker ps --filter "label=com.docker.compose.project=${BASELINE_PROJECT}" --format '  {{.Names}}  {{.Image}}  {{.Status}}'
ok "OpenClaw ${OPENCLAW_VERSION} running. Control UI: http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/  token: $RUNTIME/openclaw/gateway-token"

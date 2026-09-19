#!/usr/bin/env bash
# demo.sh — port-forward the agentgateway proxy to localhost:$PORT (default
# 8080). Point Claude Code at it with:
#   export ANTHROPIC_BASE_URL=http://localhost:8080
#   export ANTHROPIC_API_KEY=$(./scripts/mint-token.sh)   # the gateway JWT
# Ctrl-C to stop.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Port-forwarding svc/$GW_NAME -> localhost:$PORT"
log "gateway base URL: http://localhost:$PORT   (Anthropic API path: /v1/messages)"
# Not `exec kctx`: kctx is a shell function defined in lib.sh, and exec replaces the
# process with a command, so it cannot run one. That failed with "exec: kctx: not found"
# before anything was forwarded.
exec kubectl --context "$CTX" -n "$GW_NS" port-forward "svc/$GW_NAME" "${PORT}:80"

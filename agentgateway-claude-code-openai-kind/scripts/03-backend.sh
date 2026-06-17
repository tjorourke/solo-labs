#!/usr/bin/env bash
# 03-backend.sh — put the OpenAI key in a cluster Secret, create the
# AgentgatewayBackend (provider: openai) and the HTTPRoute that maps the
# Anthropic Messages path to it. After this, /v1/messages is served end to end:
# Anthropic in, OpenAI out, Anthropic back.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_openai

step "Creating the OpenAI credential Secret (held in-cluster, never on the client)"
kctx -n "$GW_NS" create secret generic openai-secret \
  --from-literal="Authorization=Bearer ${OPENAI_API_KEY}" \
  --dry-run=client -o yaml | kctx apply -f - >/dev/null
ok "secret 'openai-secret' applied"

step "Applying the AgentgatewayBackend and HTTPRoute"
kctx apply -f "$LAB_ROOT/yaml/backend.yaml" >/dev/null
kctx apply -f "$LAB_ROOT/yaml/httproute.yaml" >/dev/null
ok "backend 'openai' + route 'claude-to-openai' applied"

kctx -n "$GW_NS" get agentgatewaybackend openai 2>/dev/null | sed 's/^/  /' >&2 || true
echo "  Next: ./scripts/04-rbac.sh" >&2

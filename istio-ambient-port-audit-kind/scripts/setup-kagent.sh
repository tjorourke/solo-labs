#!/usr/bin/env bash
# setup-kagent.sh — the BONUS capability. Installs OSS kagent on the port-audit
# cluster and deploys the port-audit-reporter agent, which reads the report
# ConfigMap and publishes it to a GitHub repo as markdown via the hosted GitHub
# MCP server.
#
# Needs two secrets (export them, or put them in SECRETS_FILE):
#   ANTHROPIC_API_KEY  — the model the reporter agent runs on
#   GITHUB_PAT         — a PAT with Contents: read+write on the target repo.
#                        It is turned into the github-mcp-pat Secret and injected
#                        as the Authorization header on every GitHub MCP call.
#
#   ./scripts/setup-kagent.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

KAGENT_VERSION="${KAGENT_VERSION:-0.9.4}"
KAGENT_CRDS_CHART="${KAGENT_CRDS_CHART:-oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds}"
KAGENT_CHART="${KAGENT_CHART:-oci://ghcr.io/kagent-dev/kagent/helm/kagent}"
# Chart default model (default-model-config). The reporter agent uses its own
# ModelConfig (yaml/50-agent/10-modelconfig.yaml, claude-sonnet-5).
KAGENT_MODEL="${KAGENT_MODEL:-claude-sonnet-4-5-20250929}"

require helm; require kubectl
load_secrets
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set — export it or put it in SECRETS_FILE"
[[ -n "${GITHUB_PAT:-}" ]] || die "GITHUB_PAT not set — a PAT with Contents:read+write on the target repo"

step "Installing kagent $KAGENT_VERSION (Anthropic + built-in tool server)"
log "controller + postgres + tool-server image pulls can take a few minutes"
kc create namespace kagent --dry-run=client -o yaml | kc apply -f - >/dev/null
helm --kube-context "$CTX" upgrade --install kagent-crds "$KAGENT_CRDS_CHART" \
  --namespace kagent --version "$KAGENT_VERSION" --wait --timeout 5m >/dev/null
helm --kube-context "$CTX" upgrade --install kagent "$KAGENT_CHART" \
  --namespace kagent --version "$KAGENT_VERSION" \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey="${ANTHROPIC_API_KEY}" \
  --set providers.anthropic.model="${KAGENT_MODEL}" \
  --set kagent-tools.enabled=true \
  --wait --timeout 12m >/dev/null
wait_deploy kagent kagent-controller 360s || warn "controller not Available in 6m — continuing"
ok "kagent installed"

step "GitHub PAT secret (Authorization: Bearer <pat>)"
# A token is dynamic, so it is created here from the env var, never committed as
# YAML. The RemoteMCPServer injects this value as the Authorization header.
kc -n kagent create secret generic github-mcp-pat \
  --from-literal=authorization="Bearer ${GITHUB_PAT}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "github-mcp-pat secret ready"

step "Deploying the reporter agent + its GitHub MCP tool"
kc apply -f "$SCRIPT_DIR/../yaml/50-agent/" >/dev/null
ok "port-audit-reporter agent applied"

step "Waiting for GitHub MCP tool discovery"
for _ in $(seq 1 30); do
  n="$(kc -n kagent get remotemcpserver github-mcp -o jsonpath='{.status.discoveredTools}' 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')"
  [[ "${n:-0}" -gt 0 ]] && { ok "github-mcp discovered ${n} tools"; break; }
  sleep 3
done
kc -n kagent get remotemcpserver github-mcp -o jsonpath='{range .status.discoveredTools[*]}{.name}{"\n"}{end}' 2>/dev/null | sed 's/^/  /' >&2 || true

step "kagent bonus ready"
cat >&2 <<EOF

  Open the dashboard:   ./scripts/kagent-ui.sh   (http://localhost:8080)
  or drive it headless: ./scripts/report-to-github.sh <owner>/<repo> [path] [branch]

  In the UI, chat with the port-audit-reporter agent, for example:
    Publish the port audit to tjorourke/solo-port-test at port-audit-report.md on main
EOF

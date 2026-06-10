#!/usr/bin/env bash
# 07-runtime-deploy.sh — register a Kubernetes Runtime that points the local
# arctl daemon at the kind cluster, then deploy the agent. The registry's
# Kubernetes adapter translates the Deployment into kagent CRDs and applies them,
# so the agent ends up hosted on the kagent controller.
#
# Networking: the daemon runs in Docker, the cluster's API server is on the host.
# We join the daemon's API-server container to the kind docker network and feed
# the runtime the *internal* kubeconfig (server = kind control-plane container
# hostname), which the daemon can reach over that network and whose TLS SAN
# matches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
cd "$LAB_ROOT"
arctl_token

step "Joining the arctl daemon to the kind network"
# The container that publishes 12121 runs the registry server + Kubernetes adapter.
DAEMON_CTR="$(docker ps --filter "publish=12121" --format '{{.Names}}' | head -1)"
[[ -n "$DAEMON_CTR" ]] || die "could not find the arctl daemon container (publishing :12121)"
if [[ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$DAEMON_CTR" 2>/dev/null)" == "null" ]]; then
  docker network connect kind "$DAEMON_CTR" >/dev/null 2>&1 || true
fi
ok "daemon container '$DAEMON_CTR' on the kind network"

step "Registering the Kubernetes Runtime -> kind/kagent"
KUBECONFIG_INTERNAL="$(kind get kubeconfig --internal --name "$CLUSTER_NAME")"
RUNTIME_YAML="$(mktemp)"
{
  cat <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: kind-kagent
spec:
  type: Kubernetes
  config:
    namespace: kagent
    kubeconfig: |
EOF
  printf '%s\n' "$KUBECONFIG_INTERNAL" | sed 's/^/      /'
} > "$RUNTIME_YAML"
arctl apply -f "$RUNTIME_YAML"
rm -f "$RUNTIME_YAML"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
ok "runtime kind-kagent registered"

step "Deploying the summarizer agent onto the runtime"
# The Deployment binds the summarizer Agent to the kind-kagent Runtime and passes
# the Anthropic key the agent's model reads.
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" envsubst < yaml/deployment.yaml | arctl apply -f -
ok "deployment applied"

step "Setting the textkit MCP launch command (kmcp deployment.cmd)"
# AR runs the OCI/stdio MCP through a kmcp MCPServer whose agentgateway relay
# launches the server by an explicit command. Set the command kmcp uses so the
# relay can start the FastMCP server inside the container.
MCPSRV=""; end=$(( $(date +%s) + 150 ))
until MCPSRV="$(kc -n kagent get mcpserver -o name 2>/dev/null | grep -i textkit | head -1)"; [[ -n "$MCPSRV" ]]; do
  [[ $(date +%s) -ge $end ]] && { warn "textkit kmcp MCPServer not created in 2.5m"; break; }; sleep 3
done
if [[ -n "$MCPSRV" ]]; then
  kc -n kagent patch "$MCPSRV" --type merge \
    -p '{"spec":{"deployment":{"cmd":"python","args":["src/main.py"]}}}' >/dev/null 2>&1 \
    && ok "set ${MCPSRV##*/} command -> python src/main.py" || warn "could not set command on $MCPSRV"
  kc -n kagent rollout status "deploy/${MCPSRV##*/}" --timeout=90s >/dev/null 2>&1 || true
fi

step "Waiting for the agent to reconcile onto kagent"
AGENT_CR="$(resolve_kagent_agent summarizer)"
if [[ -n "$AGENT_CR" ]]; then
  wait_agent "$AGENT_CR" 360 && ok "kagent Agent '$AGENT_CR' is Ready" \
    || warn "agent not Ready in 6m — check: kubectl --context $CTX -n kagent get agent,pods"
else
  warn "no kagent Agent matching 'summarizer' yet — check: kubectl --context $CTX -n kagent get agent"
fi

step "Deployed"
kc -n kagent get agent,pods 2>/dev/null | sed 's/^/  /' >&2 || true
cat >&2 <<EOF

  Talk to it:   ./scripts/ask.sh "summarize this: <paste text>"
  kagent UI:    ./scripts/port-forward.sh   then open the printed URL
EOF

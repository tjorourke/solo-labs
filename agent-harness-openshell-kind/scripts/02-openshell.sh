#!/usr/bin/env bash
# 02-openshell.sh — install the OpenShell gateway + the agent-sandbox controller.
#
# OpenShell is the backend that an AgentHarness asks to provision a long-lived
# sandbox VM. It builds on the upstream agent-sandbox controller
# (sandboxes.agents.x-k8s.io). The kagent controller reaches the OpenShell
# gateway over gRPC at OPENSHELL_GRPC_ADDR (wired in 03-kagent.sh).
#
# Demo posture: TLS + auth are OFF (server.disableTls / allowUnauthenticatedUsers)
# so the lab is self-contained on kind. For anything real, terminate TLS and wire
# OIDC per the OpenShell chart's server.tls / server.oidc values.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Namespace '$OPENSHELL_NS'"
kc create namespace "$OPENSHELL_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "namespace ready"

step "Installing the agent-sandbox controller"
log "applying $AGENT_SANDBOX_MANIFEST"
kc apply -f "$AGENT_SANDBOX_MANIFEST" >/dev/null
ok "agent-sandbox manifest applied (sandboxes.agents.x-k8s.io)"

log "waiting for the agent-sandbox controller..."
wait_pods_ready agent-sandbox-system "app=agent-sandbox-controller" 240s \
  || warn "agent-sandbox controller not confirmed Ready — continuing (check: kubectl -n agent-sandbox-system get pods)"

step "Installing OpenShell $OPENSHELL_VERSION"
log "image pulls (gateway + supervisor) can take 2-4 min on a cold cluster — progress every 15s"
helm_install_with_progress openshell "$OPENSHELL_CHART" "$OPENSHELL_NS" \
  --version "$OPENSHELL_VERSION" \
  --set fullnameOverride="$OPENSHELL_FULLNAME" \
  --set server.disableTls=true \
  --set server.auth.allowUnauthenticatedUsers=true
ok "OpenShell chart installed"

step "Waiting for the OpenShell gateway"
# The gateway is a StatefulSet; certgen runs as a pre-install Job first.
kc -n "$OPENSHELL_NS" rollout status statefulset/"$OPENSHELL_FULLNAME" --timeout=300s >/dev/null \
  || warn "OpenShell gateway not confirmed Ready in 5m — check: kubectl -n $OPENSHELL_NS get pods"
ok "OpenShell gateway ready at ${OPENSHELL_GRPC_ADDR}"

step "OpenShell installed"
echo "  Gateway gRPC: $OPENSHELL_GRPC_ADDR" >&2
echo "  Next:         ./scripts/03-kagent.sh" >&2

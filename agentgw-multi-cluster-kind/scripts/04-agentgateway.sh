#!/usr/bin/env bash
# Step 4 — install Solo Enterprise agentgateway on both clusters.
#
# Two deployments per cluster:
#   1. North-south ingress (enterprise-agentgateway GatewayClass)
#      Replaces: gatewayClassName: istio (Istio Ingress Gateway)
#      Listens on :8080 (HTTP) / :8443 (HTTPS) via MetalLB LoadBalancer
#
#   2. Waypoint / east-west (enterprise-agentgateway-waypoint GatewayClass)
#      Replaces: gatewayClassName: istio-eastwest (Istio East-West Gateway)
#      at the L7 AI/MCP enforcement layer.
#      The Istio HBONE east-west gateway (installed in 03-istio.sh) remains
#      as the mesh fabric — this waypoint intercepts L7 MCP traffic on top.
#
# Prerequisites:
#   AGENTGATEWAY_LICENSE_KEY — enterprise license key (from secrets-envs.sh)
#   helm, kubectl

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$REPO_ROOT/.env" ]] && { set -a; source "$REPO_ROOT/.env"; set +a; }

CLUSTER1="${CLUSTER1:-kind-east}"
CLUSTER2="${CLUSTER2:-kind-west}"
CLUSTERS=("$CLUSTER1" "$CLUSTER2")
CLUSTER_NAMES=("east" "west")

# Enterprise agentgateway v2026.5.1 (calver, succeeds v2.3.x) is the GA default.
# Registry path is `enterprise-agentgateway/charts/...` — the swapped
# `agentgateway-enterprise/charts/...` form 404s on the public Solo registry.
AGW_VERSION="${AGENTGATEWAY_ENTERPRISE_VERSION:-v2026.5.1}"
AGW_CHART="${AGENTGATEWAY_ENTERPRISE_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway}"
AGW_CRDS_CHART="${AGENTGATEWAY_ENTERPRISE_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds}"

[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || {
  echo "ERROR: AGENTGATEWAY_LICENSE_KEY not set (source secrets-envs.sh first)"
  exit 1
}

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "==> $*"; }

# ---------- CRDs ----------
step "Installing Enterprise agentgateway CRDs $AGW_VERSION"
for ctx in "${CLUSTERS[@]}"; do
  log "[${ctx#kind-}] helm install enterprise-agentgateway-crds..."
  helm --kube-context "$ctx" upgrade --install agentgateway-crds "$AGW_CRDS_CHART" \
    --namespace agentgateway-system --create-namespace \
    --version "$AGW_VERSION" \
    --wait --timeout 3m >/dev/null
  log_ok "[${ctx#kind-}] CRDs installed"
done

# ---------- Control plane (north-south ingress mode) ----------
step "Installing Enterprise agentgateway $AGW_VERSION (north-south ingress)"
for i in "${!CLUSTERS[@]}"; do
  ctx="${CLUSTERS[$i]}"
  name="${CLUSTER_NAMES[$i]}"
  log "[$name] helm install agentgateway-enterprise..."
  helm --kube-context "$ctx" upgrade --install agentgateway "$AGW_CHART" \
    --namespace agentgateway-system \
    --version "$AGW_VERSION" \
    --set licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
    --set clusterName="$name" \
    --wait --timeout 5m >/dev/null
  log_ok "[$name] Enterprise agentgateway installed"
done

# ---------- North-south Gateway resource ----------
step "Applying north-south Gateway (enterprise-agentgateway)"
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" apply -f \
    "$REPO_ROOT/yaml/agentgateway/gateway-north-south.yaml" >/dev/null
  log_ok "[${ctx#kind-}] agw-ingress Gateway applied"
done

# Wait for the LoadBalancer IP to be assigned.
step "Waiting for LoadBalancer IPs"
for ctx in "${CLUSTERS[@]}"; do
  name="${ctx#kind-}"
  echo -n "  [$name] waiting for agw-ingress external IP..."
  for i in $(seq 1 30); do
    IP="$(kubectl --context "$ctx" -n agentgateway-system \
      get svc agw-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "$IP" ]]; then
      echo " $IP"
      break
    fi
    echo -n "."
    sleep 3
  done
  [[ -n "$IP" ]] || echo " (timeout — check MetalLB)"
done

# ---------- Waypoint Gateway resource ----------
step "Applying waypoint Gateway (enterprise-agentgateway-waypoint)"
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" apply -f \
    "$REPO_ROOT/yaml/agentgateway/waypoint.yaml" >/dev/null
  log_ok "[${ctx#kind-}] agw-waypoint Gateway applied"
done

# Label the echo-mcp Service to use the waypoint (applied after demo workloads
# are deployed in 05-demo-workloads.sh; also done here defensively).
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" -n ai-demo annotate svc echo-mcp \
    "istio.io/use-waypoint=agw-waypoint" --overwrite >/dev/null 2>&1 || true
done

# ---------- Backends, HTTPRoutes, Policies ----------
step "Applying AgentgatewayBackends + HTTPRoutes"
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" apply -f \
    "$REPO_ROOT/yaml/agentgateway/backends.yaml" >/dev/null
  kubectl --context "$ctx" apply -f \
    "$REPO_ROOT/yaml/agentgateway/httproutes.yaml" >/dev/null
  log_ok "[${ctx#kind-}] backends + httproutes applied"
done

step "Applying EnterpriseAgentgatewayPolicy resources"
for ctx in "${CLUSTERS[@]}"; do
  kubectl --context "$ctx" apply -f \
    "$REPO_ROOT/yaml/agentgateway/policies.yaml" >/dev/null
  log_ok "[${ctx#kind-}] policies applied"
done

# ---------- Summary ----------
step "Installation complete"
for ctx in "${CLUSTERS[@]}"; do
  name="${ctx#kind-}"
  IP="$(kubectl --context "$ctx" -n agentgateway-system \
    get svc agw-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")"
  echo "  [$name] agw-ingress: http://${IP}:8080"
done

echo ""
echo "Verify:"
echo "  kubectl --context kind-east -n agentgateway-system get gateway,svc"
echo "  kubectl --context kind-east -n ai-demo get gateway agw-waypoint"
echo ""
echo "Next: ./scripts/05-demo-workloads.sh"

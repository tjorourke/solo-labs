#!/usr/bin/env bash
# reset.sh — hard reset the DEMO back to square 1, keeping the PLATFORM intact.
#
# Wipes every demo workload from both parts (bookinfo on both clusters, petshop,
# warehouse — apps, gateways, waypoints, HTTPRoutes, AuthorizationPolicies,
# EnterpriseAgentgatewayPolicies, the global ServiceEntry, demo-client, the
# tier annotations) and reverts ztunnel to claims-off, so the next run starts
# from a clean slate — but leaves the clusters, ambient mesh, peering,
# agentgateway, Gloo UI and Keycloak up, so there is NO rebuild.
#
# Use this between demo runs. It is the "restart the whole demo" button.
#   - 1.R / 2.R in the notebook are lighter, per-part soft resets (they keep the
#     app deployed for a quick re-run of that one part).
#   - ./setup.sh teardown deletes the clusters entirely (full ~20-min rebuild).
#
#   ./demo-scripts/reset.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

require kubectl; require helm

step "Deleting demo namespaces (both clusters) — apps, gateways, policies, labels, ServiceEntries"
# Deleting the namespaces removes EVERYTHING in one shot: bookinfo/petshop/
# warehouse workloads, the agentgateway ingress + waypoints, all HTTPRoutes and
# policies, the reviews global-service label (so istiod drops the autogen
# ServiceEntry), and demo-client. Keycloak + the platform namespaces are left
# untouched.
kubectl --context "$CLUSTER1" delete namespace bookinfo petshop warehouse --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl --context "$CLUSTER2" delete namespace bookinfo --ignore-not-found --wait=false >/dev/null 2>&1 || true

log "waiting for the namespaces to finish terminating…"
for ns in bookinfo petshop warehouse; do
  kubectl --context "$CLUSTER1" wait --for=delete "namespace/$ns" --timeout=150s >/dev/null 2>&1 || true
done
kubectl --context "$CLUSTER2" wait --for=delete namespace/bookinfo --timeout=150s >/dev/null 2>&1 || true
ok "demo namespaces removed"

# The reviews global-service creates an autogen ServiceEntry in istio-system;
# istiod removes it when the Service is gone, but sweep any straggler by name.
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n "$ISTIO_SYSTEM_NS" delete serviceentry \
    -l 'solo.io/service-scope' --ignore-not-found >/dev/null 2>&1 || true
done

step "Reverting ztunnel to claims-off on ${CLUSTER1#kind-} (if Part 2 §2.7 turned it on)"
CLAIMS="$(kubectl --context "$CLUSTER1" -n "$ISTIO_SYSTEM_NS" get ds ztunnel \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_WORKLOAD_CLAIMS")].value}' 2>/dev/null || true)"
if [[ "$CLAIMS" == "true" ]]; then
  helm --kube-context "$CLUSTER1" upgrade -i ztunnel "$ISTIO_HELM_REPO/ztunnel" \
    -n "$ISTIO_SYSTEM_NS" --version "$ISTIO_HELM_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${ISTIO_VERSION}
namespace: ${ISTIO_SYSTEM_NS}
istioNamespace: ${ISTIO_SYSTEM_NS}
multiCluster:
  clusterName: ${CLUSTER1_NAME}
network: ${CLUSTER1_NAME}
platforms:
  peering:
    enabled: true
env:
  LOG_FORMAT: json
  L7_ENABLED: "true"
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
EOF
  kubectl --context "$CLUSTER1" -n "$ISTIO_SYSTEM_NS" rollout status daemonset/ztunnel --timeout=180s >/dev/null
  ok "ztunnel reverted to claims-off"
else
  ok "ztunnel already claims-off — nothing to revert"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Demo reset — back to square 1 (platform still up, no rebuild)"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Restart the demo: open demo.ipynb, run Connect, then Part 1 / Part 2"
echo "  from the top (§1.1 redeploys bookinfo, §2.1 redeploys petshop)."
echo ""
echo "  Platform left intact: clusters, ambient mesh, peering, agentgateway,"
echo "  Gloo UI (${CLUSTER1#kind-}+${CLUSTER2#kind-}), Keycloak."
echo ""

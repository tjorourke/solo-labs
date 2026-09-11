#!/usr/bin/env bash
# platform.sh: the parts of the cluster every lab in the series shares.
#
#   up        seed the sre-lab namespace; put the agentgateway waypoint, the per-agent
#             tool policy and the L4 authorization in front of kagent-tools; register the
#             sre-tools catalogue entry. Idempotent, so every part can call it.
#   teardown  remove all of it.
#
# Assumes an existing cluster with Solo Enterprise for kagent, enterprise agentgateway
# and an ambient mesh with the kagent namespace enrolled. Nothing here installs those.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
YAML="$SCRIPT_DIR/../yaml"

preflight() {
  step "Preflight on $CTX"
  kc get crd agents.kagent.dev >/dev/null 2>&1 || die "kagent is not installed on $CTX (no agents.kagent.dev CRD)"
  kc get crd enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io >/dev/null 2>&1 \
    || die "enterprise agentgateway is not installed on $CTX"
  kc -n "$NS" get deploy kagent-controller >/dev/null 2>&1 || die "no kagent-controller Deployment in $NS"
  kc -n "$NS" get deploy kagent-tools >/dev/null 2>&1 || die "no kagent-tools Deployment in $NS; the series uses it as the tool server"
  [[ "$(kc get ns "$NS" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" == "ambient" ]] \
    || die "namespace $NS is not ambient-enrolled (label istio.io/dataplane-mode=ambient); the waypoint needs it"
  kc -n "$NS" get modelconfig default-model-config >/dev/null 2>&1 || die "no default-model-config ModelConfig in $NS"
  ok "kagent, agentgateway, ambient and a model config are present"
}

up() {
  preflight
  step "Seeding the $SRE_NS namespace"
  kc apply -f "$YAML/00-sre-namespace.yaml" >/dev/null
  # The healthy ones become Available; the broken ones are meant to stay broken.
  local d; for d in payments-api orders-api catalogue; do
    kc -n "$SRE_NS" rollout status deploy/"$d" --timeout=180s >/dev/null
  done
  ok "$SRE_NS seeded: 3 healthy, 4 broken (checkout, search, report-worker, ml-scorer)"

  step "Waypoint in front of kagent-tools"
  kc apply -f "$YAML/10-sre-tools-gateway.yaml" >/dev/null
  wait_gateway_programmed sre-tools-waypoint
  kc apply -f "$YAML/40-sre-tools-remotemcpserver.yaml" >/dev/null
  ok "sre-tools.kagent.svc.cluster.local is served by the waypoint"

  step "Per-agent tool policy and L4 authorization"
  kc apply -f "$YAML/20-tool-policy.yaml" >/dev/null
  local td; td="$(trust_domain)"
  sed "s|\${TRUST_DOMAIN}|$td|g" "$YAML/30-tools-authz.yaml" | kc apply -f - >/dev/null
  ok "policy applied; kagent-tools:8084 refuses the series agents directly (trust domain $td)"
}

teardown() {
  step "Removing the shared platform pieces from $CTX"
  kc delete -f "$YAML/30-tools-authz.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kc delete -f "$YAML/20-tool-policy.yaml" --ignore-not-found >/dev/null
  kc delete -f "$YAML/40-sre-tools-remotemcpserver.yaml" --ignore-not-found >/dev/null
  kc delete -f "$YAML/10-sre-tools-gateway.yaml" --ignore-not-found >/dev/null
  kc delete -f "$YAML/00-sre-namespace.yaml" --ignore-not-found --wait=false >/dev/null
  ok "removed"
}

case "${1:-up}" in
  up) up ;;
  teardown) teardown ;;
  *) echo "Usage: $0 up | teardown" >&2; exit 2 ;;
esac

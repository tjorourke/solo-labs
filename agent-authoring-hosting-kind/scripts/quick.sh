#!/usr/bin/env bash
# quick.sh: Part 6 of the agent-authoring series, on an existing cluster.
#   ./scripts/quick.sh up        Part 1's shared pieces, then this part's model waypoint, tool
#                                endpoint, agents, A2A policy, egress policy and JWT edge route
#   ./scripts/quick.sh test      the containment checks (scripts/check.sh)
#   ./scripts/quick.sh teardown  remove this part's objects; Part 1's shared pieces stay
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
YAML="$SCRIPT_DIR/../yaml"
export INGRESS_GATEWAY="${INGRESS_GATEWAY:-ar-ingress}"
export INGRESS_GATEWAY_NS="${INGRESS_GATEWAY_NS:-agentgateway-system}"

# The edge route and its JWT policy carry the ingress address and the Keycloak issuer,
# which differ per cluster; both are read from the cluster and substituted at apply time.
render_edge() {
  local lb url
  lb="$(kc -n "$INGRESS_GATEWAY_NS" get gateway "$INGRESS_GATEWAY" -o jsonpath='{.status.addresses[0].value}')"
  [[ -n "$lb" ]] || die "gateway $INGRESS_GATEWAY_NS/$INGRESS_GATEWAY has no address"
  url="$(keycloak_url)"
  [[ -n "$url" ]] || die "no Keycloak URL: set KEYCLOAK_URL"
  sed -e "s|\${LB_ADDRESS}|$lb|g" -e "s|\${KEYCLOAK_URL}|$url|g" -e "s|\${KEYCLOAK_REALM}|$KEYCLOAK_REALM|g" "$YAML/60-edge-route.yaml"
}

case "${1:-up}" in
  up)
    bash "$PART1/scripts/platform.sh" up
    step "Model waypoint and model config"
    kc apply -f "$YAML/10-model-egress.yaml" -f "$YAML/20-model-config.yaml" >/dev/null
    wait_gateway_programmed sre-model-waypoint
    ok "api.anthropic.com is reached only through sre-model.$NS.svc.cluster.local"

    step "Tool endpoint for one agent"
    kc apply -f "$YAML/30-tools-endpoint.yaml" -f "$YAML/40-tools-policy.yaml" >/dev/null
    wait_gateway_programmed contained-tools-waypoint
    sed "s|\${TRUST_DOMAIN}|$(trust_domain)|g" "$YAML/80-tools-authz.yaml" | kc apply -f - >/dev/null
    ok "contained-tools serves sre-contained and nobody else"

    step "Agents, A2A policy and egress policy"
    kc apply -f "$YAML/50-agent.yaml" -f "$YAML/55-other-agent.yaml" -f "$YAML/90-a2a.yaml" -f "$YAML/70-egress-policy.yaml" >/dev/null
    wait_agent_ready sre-contained; wait_agent_ready sre-other; wait_agent_ready sre-caller
    wait_gateway_programmed agent-sre-contained-waypoint
    ok "sre-contained, sre-caller and sre-other are Ready"

    step "Edge route with a Strict JWT policy"
    render_edge | kc apply -f - >/dev/null
    ok "contained-tools.$(kc -n "$INGRESS_GATEWAY_NS" get gateway "$INGRESS_GATEWAY" -o jsonpath='{.status.addresses[0].value}').sslip.io requires a token"
    cat >&2 <<MSG

  Part 6 is up on $CTX.

    ./scripts/check.sh                       # every containment claim, executed
    ./scripts/probe-as.sh sre-contained      # tools/list as that identity
    ./scripts/probe-as.sh sre-python         # and as an identity the endpoint does not know
    ./scripts/call-edge.sh                   # the published route, without and with a token
    ./scripts/audit-endpoints.sh             # every way into the cluster's gateways
    ../agent-authoring-contract-kind/scripts/ask.sh sre-caller "Which pods in $SRE_NS are unhealthy, and why?"
MSG
    ;;
  test) bash "$SCRIPT_DIR/check.sh" ;;
  teardown)
    step "Removing Part 6 from $CTX"
    render_edge 2>/dev/null | kc delete --ignore-not-found -f - >/dev/null 2>&1 || true
    kc delete -f "$YAML/90-a2a.yaml" -f "$YAML/70-egress-policy.yaml" -f "$YAML/55-other-agent.yaml" -f "$YAML/50-agent.yaml" --ignore-not-found >/dev/null
    kc delete -f "$YAML/80-tools-authz.yaml" --ignore-not-found >/dev/null 2>&1 || kc -n "$NS" delete authorizationpolicy kagent-tools-no-direct-contained --ignore-not-found >/dev/null
    kc delete -f "$YAML/40-tools-policy.yaml" -f "$YAML/30-tools-endpoint.yaml" -f "$YAML/20-model-config.yaml" -f "$YAML/10-model-egress.yaml" --ignore-not-found >/dev/null
    ok "removed; Part 1's shared pieces stay"
    ;;
  *) echo "Usage: $0 up | test | teardown" >&2; exit 2 ;;
esac

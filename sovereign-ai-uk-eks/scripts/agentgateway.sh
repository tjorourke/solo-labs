#!/usr/bin/env bash
# Install Enterprise agentgateway, the single door in front of the model.
#
#   ./scripts/agentgateway.sh up      Gateway API CRDs + agentgateway CRDs + control plane
#   ./scripts/agentgateway.sh route   apply the Gateway and the vLLM LLM backend
#   ./scripts/agentgateway.sh url     the gateway's public NLB hostname
#   ./scripts/agentgateway.sh test    a real chat completion through the gateway
#   ./scripts/agentgateway.sh status  what is installed and whether the route attached
#
# Phase 1 built the model and phase 2 the policy lane, but nothing in the lab ever
# installed the gateway itself, so yaml/30- onwards had no CRDs to validate against.
# This is that missing step.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
GW_NS=agentgateway-system

# Public Solo chart registry, so no helm registry login is needed. Only the nightly
# dev repo on pkg.dev requires auth, and it is not used here.
AGW_REG="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts"
AGW_VERSION="${AGW_VERSION:-v2026.7.0}"
# Experimental, not standard. The standard channel omits ListenerSet and the
# BackendTLSPolicy shapes the enterprise chart expects, and the failure is a
# confusing CRD-not-found at install rather than anything about channels.
GWAPI_VERSION="${GWAPI_VERSION:-v1.4.0}"

# Derived, never hardcoded. This file is published from the site, and deriving it also
# guarantees it matches whichever profile is actually in effect.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kubectl() { command kubectl --context "$CTX" "$@"; }
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The licence is never in this repo. Export AGENTGATEWAY_LICENSE_KEY yourself, or point
# SOVEREIGN_ENV_FILE at your own env file that exports it.
license() {
  if [ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]; then
    # Optional convenience: point SOVEREIGN_ENV_FILE at your own env file that exports
    # the licence keys. Otherwise export them directly. No path is hardcoded, and no
    # secret ever lives in this repo.
    # shellcheck disable=SC1090
    [ -n "${SOVEREIGN_ENV_FILE:-}" ] && [ -f "$SOVEREIGN_ENV_FILE" ] && . "$SOVEREIGN_ENV_FILE" >/dev/null 2>&1 || true
  fi
  [ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ] || {
    echo "error: AGENTGATEWAY_LICENSE_KEY is not set. source your secrets env first." >&2; exit 1; }
}

gw_host() {
  kubectl -n "$GW_NS" get svc sovereign-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

case "${1:-status}" in
  up)
    license

    echo "==> Gateway API $GWAPI_VERSION (experimental channel)"
    # --server-side: the experimental CRDs carry a last-applied annotation that blows
    # past the 256KB client-side apply limit ("metadata.annotations: Too long").
    kubectl apply --server-side --force-conflicts \
      -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml" >/dev/null
    echo "    applied"

    echo "==> Enterprise agentgateway CRDs $AGW_VERSION"
    helm upgrade --install agentgateway-crds "${AGW_REG}/enterprise-agentgateway-crds" \
      --kube-context "$CTX" --namespace "$GW_NS" --create-namespace \
      --version "$AGW_VERSION" --wait >/dev/null
    echo "    installed"

    echo "==> Enterprise agentgateway control plane $AGW_VERSION"
    helm upgrade --install enterprise-agentgateway "${AGW_REG}/enterprise-agentgateway" \
      --kube-context "$CTX" --namespace "$GW_NS" \
      --version "$AGW_VERSION" \
      --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
      --wait --timeout 5m >/dev/null
    echo "    installed"

    # The control plane must be up before the Gateway is created, or the Service that
    # fronts it never gets provisioned and `url` returns empty forever.
    #
    # The Deployment is `enterprise-agentgateway`, matching the release name, with no
    # -controller suffix. Verified on the cluster: guessing the suffix fails the whole
    # stage with a NotFound after both charts have installed perfectly well.
    kubectl -n "$GW_NS" rollout status deploy/enterprise-agentgateway --timeout=300s
    # The GatewayClass being Accepted is the real readiness signal for what comes next,
    # since 30-gateway.yaml selects it by name.
    kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
      gatewayclass/enterprise-agentgateway --timeout=120s
    ;;

  route)
    echo "==> Gateway + LLM backend + route"
    kubectl apply -f "$LAB_ROOT/yaml/30-gateway.yaml"
    kubectl apply -f "$LAB_ROOT/yaml/31-vllm-backend.yaml"
    echo "==> MCP tool server + per-tool authorization (keyed on JWT groups)"
    kubectl apply -f "$LAB_ROOT/yaml/60-mcp-tools.yaml"
    kubectl apply -f "$LAB_ROOT/yaml/61-mcp-authz.yaml"
    echo
    echo "==> waiting for the NLB to get a hostname (AWS takes 2-4 min)"
    for _ in $(seq 1 40); do
      h="$(gw_host)"; [ -n "$h" ] && { echo "    $h"; break; }
      sleep 15
    done
    [ -n "$(gw_host)" ] || echo "    still no hostname; check: kubectl -n $GW_NS describe svc sovereign-gateway"
    ;;

  url)
    h="$(gw_host)"
    [ -n "$h" ] || { echo "no LoadBalancer hostname yet" >&2; exit 1; }
    echo "http://${h}"
    ;;

  test)
    h="$(gw_host)"
    [ -n "$h" ] || { echo "error: no gateway hostname; run '$0 route' first" >&2; exit 1; }
    # An NLB answers DNS before it is passing health checks, so a curl straight after
    # `route` can fail on a gateway that is fine. Retry rather than concluding.
    echo "==> POST http://${h}/v1/chat/completions"
    for i in $(seq 1 20); do
      code="$(curl -s -o /tmp/agw-test.json -w '%{http_code}' --max-time 120 \
        -X POST "http://${h}/v1/chat/completions" \
        -H 'content-type: application/json' \
        -d '{"model":"mistral-small-3.2-24b","max_tokens":80,
             "messages":[{"role":"user","content":"In one sentence: where are you running, and why does that matter for UK data sovereignty?"}]}' || echo 000)"
      if [ "$code" = "200" ]; then
        echo
        python3 -c 'import json,sys;d=json.load(open("/tmp/agw-test.json"));print(d["choices"][0]["message"]["content"].strip());print();print("model:",d.get("model"),"| tokens:",d.get("usage"))'
        exit 0
      fi
      echo "    attempt $i: HTTP $code, retrying"
      sleep 15
    done
    echo "==> never got a 200. Last body:" >&2
    cat /tmp/agw-test.json >&2; echo >&2
    exit 1
    ;;

  status)
    echo "=== helm releases in $GW_NS"
    helm list --kube-context "$CTX" -n "$GW_NS" 2>/dev/null || true
    echo
    echo "=== control plane"
    kubectl -n "$GW_NS" get pods 2>/dev/null || echo "  namespace not present"
    echo
    echo "=== Gateway"
    kubectl -n "$GW_NS" get gateway sovereign-gateway 2>/dev/null || echo "  not created"
    echo
    # A route that reports no parents is the usual reason a call 404s while every
    # object looks healthy, so it is worth printing rather than inferring.
    echo "=== HTTPRoute attachment (Accepted here is the thing that matters)"
    kubectl -n "$GW_NS" get httproute vllm-mistral \
      -o jsonpath='{range .status.parents[*]}{.parentRef.name}{": "}{range .conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}' 2>/dev/null \
      || echo "  not created"
    echo
    echo "=== LoadBalancer"
    kubectl -n "$GW_NS" get svc sovereign-gateway 2>/dev/null || echo "  not created"
    ;;

  *) echo "usage: $0 {up|route|url|test|status}"; exit 1 ;;
esac

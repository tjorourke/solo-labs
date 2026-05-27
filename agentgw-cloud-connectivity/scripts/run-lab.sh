#!/usr/bin/env bash
# run-lab.sh — execute the Cloud Connectivity Lab end-to-end on top of an
# already-up agentgw-multi-cluster-kind standup. Mirrors the steps at
# https://tjorourke.github.io/solo/agentgw-cloud-connectivity/
#
# Usage:
#   ./scripts/run-lab.sh [lab0|lab1|lab2|lab3|all]   (default: all)
#
# Each sub-lab is idempotent — re-running is safe.
#
# Manual steps that this script skips (require human interaction):
#   - LAB 2 browser test for user=jason (cookie-based, no CLI equivalent).

set -Eeuo pipefail

CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"
SCOPE="${1:-all}"

step() { printf '\n══> %s\n' "$*"; }
log()  { printf '   • %s\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }

# wait for the standup health-check to be green before doing anything else
preflight() {
  step "Preflight: standup must be green"
  local hc; hc="$(dirname "$0")/../../agentgw-multi-cluster-kind/scripts/health-check.sh"
  if [[ -x "$hc" ]]; then
    "$hc" || die "standup health-check failed — fix the standup first"
  else
    warn "standup health-check.sh not present — assuming standup is healthy"
  fi
}

# ── LAB 0 — Bookinfo + agentgateway ingress ────────────────────────────────
lab0() {
  step "LAB 0 — deploy Bookinfo + ingress"
  for CTX in "$CLUSTER1" "$CLUSTER2"; do
    log "[$CTX] namespace + labels"
    kubectl --context "$CTX" create namespace bookinfo 2>/dev/null || true
    kubectl --context "$CTX" label namespace bookinfo \
      istio.io/dataplane-mode=ambient \
      "topology.istio.io/network=${CTX#kind-}" --overwrite >/dev/null

    log "[$CTX] applying bookinfo manifests"
    local BOOK="https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube"
    kubectl --context "$CTX" apply -n bookinfo -f "$BOOK/bookinfo.yaml" >/dev/null
    kubectl --context "$CTX" apply -n bookinfo -f "$BOOK/bookinfo-versions.yaml" >/dev/null

    log "[$CTX] waiting for productpage Ready"
    kubectl --context "$CTX" -n bookinfo wait \
      --for=condition=Ready pod -l app=productpage --timeout=180s >/dev/null
    ok "[$CTX] bookinfo Ready"
  done

  step "Mark productpage as global multicluster service"
  for CTX in "$CLUSTER1" "$CLUSTER2"; do
    kubectl --context "$CTX" label svc productpage -n bookinfo \
      solo.io/service-scope=global --overwrite >/dev/null
    ok "[$CTX] productpage labeled solo.io/service-scope=global"
  done

  step "Confirm globally shared service registered"
  if istioctl --context "$CLUSTER1" multicluster check 2>&1 | grep -q "1 globally shared service"; then
    ok "globally shared service detected by istioctl"
  else
    warn "no globally shared service detected yet — istiod may need ~10s"
    sleep 10
    istioctl --context "$CLUSTER1" multicluster check 2>&1 | grep "Shared Services" || true
  fi

  step "Apply agentgateway ingress (Gateway + HTTPRoute) on east"
  kubectl --context "$CLUSTER1" apply -f - <<'EOF' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes: { namespaces: { from: Same } }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: productpage
  namespace: bookinfo
spec:
  parentRefs:
  - name: bookinfo-gateway
  rules:
  - backendRefs:
    - kind: Hostname
      group: networking.istio.io
      name: productpage.bookinfo.mesh.internal
      port: 9080
EOF

  log "waiting for Gateway Programmed"
  kubectl --context "$CLUSTER1" -n bookinfo wait \
    --for=condition=Programmed gateway/bookinfo-gateway --timeout=120s >/dev/null
  log "waiting for backing agentgateway pod Ready"
  kubectl --context "$CLUSTER1" -n bookinfo wait \
    --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=bookinfo-gateway \
    --timeout=180s >/dev/null
  ok "ingress Gateway + HTTPRoute up"

  step "Verify ingress: port-forward + curl /productpage"
  kubectl --context "$CLUSTER1" -n bookinfo port-forward svc/bookinfo-gateway 8080:8080 \
    >/tmp/run-lab-pf.log 2>&1 &
  local PF_PID=$!
  trap 'kill '"$PF_PID"' 2>/dev/null || true' EXIT
  sleep 3
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/productpage || echo 000)"
  kill "$PF_PID" 2>/dev/null || true; trap - EXIT
  if [[ "$code" == "200" ]]; then
    ok "ingress returned HTTP 200"
  else
    die "ingress returned HTTP $code (expected 200)"
  fi
}

# ── LAB 1 — cross-cluster failover via *.mesh.internal ─────────────────────
lab1() {
  step "LAB 1 — mesh-layer cross-cluster failover"
  log "scaling productpage-v1 to 0 on $CLUSTER1"
  kubectl --context "$CLUSTER1" scale deploy productpage-v1 -n bookinfo --replicas=0 >/dev/null
  kubectl --context "$CLUSTER1" -n bookinfo wait --for=delete pod -l app=productpage --timeout=60s >/dev/null || true
  ok "productpage scaled to 0 on $CLUSTER1"

  step "Confirm global VIP is healthy, local has 0 endpoints"
  istioctl --context "$CLUSTER1" ztunnel-config service 2>/dev/null | grep productpage || true

  step "In-mesh curl through global hostname (expect HTTP 200)"
  # The "ingress" path on agentgateway dataplane NACKs the synthetic cross-cluster
  # WorkloadEntry (documented bug — see lab page). The in-mesh path always works.
  local out
  out="$(kubectl --context "$CLUSTER1" -n bookinfo run mesh-curl \
          --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
          curl -sS -o /dev/null -w 'HTTP %{http_code} via %{remote_ip}\n' \
          http://productpage.bookinfo.mesh.internal:9080/productpage 2>&1 || true)"
  echo "   ▸ $out"
  if echo "$out" | grep -q 'HTTP 200'; then
    ok "cross-cluster failover green (200 via 240.240.x.x)"
  else
    warn "failover did not return 200 — istiod may need ~30s after scale-down"
  fi

  step "Compare: short hostname does NOT fail over (expected HTTP 000)"
  out="$(kubectl --context "$CLUSTER1" -n bookinfo run mesh-curl-short \
          --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
          curl -sS -o /dev/null -m 5 -w 'HTTP %{http_code}\n' \
          http://productpage:9080/productpage 2>&1 || true)"
  echo "   ▸ $out"

  step "Restore productpage-v1 to 1 replica on $CLUSTER1"
  kubectl --context "$CLUSTER1" scale deploy productpage-v1 -n bookinfo --replicas=1 >/dev/null
  kubectl --context "$CLUSTER1" -n bookinfo wait --for=condition=Ready pod -l app=productpage --timeout=120s >/dev/null
  ok "productpage restored"
}

# ── LAB 2 — agentgateway waypoint (header-based reviews routing) ───────────
lab2() {
  step "LAB 2 — L7 routing via enterprise-agentgateway-waypoint"
  log "applying EnterpriseAgentgatewayParameters + waypoint Gateway"
  kubectl --context "$CLUSTER1" apply -f - <<EOF >/dev/null
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: waypoint-params
  namespace: bookinfo
spec:
  istioClusterId: ${CLUSTER1#kind-}
  ca:
    trustDomain: cluster.local
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agw-waypoint
  namespace: bookinfo
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  listeners:
    - name: proxy
      port: 15008
      protocol: HBONE
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: waypoint-params
EOF
  kubectl --context "$CLUSTER1" -n bookinfo wait \
    --for=condition=Programmed gateway/agw-waypoint --timeout=120s >/dev/null
  ok "agw-waypoint Programmed"

  log "labelling namespace istio.io/use-waypoint=agw-waypoint"
  kubectl --context "$CLUSTER1" label namespace bookinfo \
    istio.io/use-waypoint=agw-waypoint --overwrite >/dev/null
  sleep 5
  if istioctl --context "$CLUSTER1" ztunnel-config service 2>/dev/null | grep -q "bookinfo.*agw-waypoint"; then
    ok "ztunnel sees agw-waypoint for bookinfo services"
  else
    warn "ztunnel hasn't picked up the waypoint yet — usually resolves within 10-20s"
  fi

  log "applying header-based reviews HTTPRoute"
  kubectl --context "$CLUSTER1" apply -f - <<'EOF' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: bookinfo
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: reviews
    port: 9080
  rules:
  - matches:
    - headers:
      - name: end-user
        value: jason
    backendRefs:
    - name: reviews-v2
      port: 9080
  - backendRefs:
    - name: reviews-v1
      port: 9080
EOF
  ok "reviews HTTPRoute applied"

  step "Test: anonymous user (expect reviews-v1, no stars)"
  kubectl --context "$CLUSTER1" -n bookinfo port-forward svc/bookinfo-gateway 8080:8080 \
    >/tmp/run-lab-pf-lab2.log 2>&1 &
  local PF_PID=$!
  trap 'kill '"$PF_PID"' 2>/dev/null || true' EXIT
  sleep 3
  if curl -s http://localhost:8080/productpage | grep -q "glyphicon-star"; then
    warn "saw star glyph — header routing may not be in effect"
  else
    ok "no star glyph in default response (reviews-v1)"
  fi
  kill "$PF_PID" 2>/dev/null || true; trap - EXIT

  log "browser test for end-user=jason (black stars) is manual — skipping"
}

# ── LAB 3 — egress with SPIFFE-identity authz ──────────────────────────────
lab3() {
  step "LAB 3 — egress via enterprise-agentgateway-waypoint"
  kubectl --context "$CLUSTER1" create namespace istio-egress 2>/dev/null || true
  kubectl --context "$CLUSTER1" apply -f - <<'EOF' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: egress-gateway
  namespace: istio-egress
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  listeners:
  - name: mesh
    port: 15088
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
  kubectl --context "$CLUSTER1" -n istio-egress wait \
    --for=condition=Programmed gateway/egress-gateway --timeout=120s >/dev/null
  ok "egress-gateway Programmed"

  kubectl --context "$CLUSTER1" label ns istio-egress \
    istio.io/use-waypoint=egress-gateway --overwrite >/dev/null

  log "applying httpbin.org ServiceEntry + DestinationRule + AuthorizationPolicy"
  kubectl --context "$CLUSTER1" apply -f - <<'EOF' >/dev/null
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin.org
  namespace: bookinfo
  labels:
    istio.io/use-waypoint: egress-gateway
    istio.io/use-waypoint-namespace: istio-egress
spec:
  hosts:
  - httpbin.org
  ports:
  - number: 80
    name: http
    protocol: HTTP
    targetPort: 443
  resolution: DNS
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin.org-tls
  namespace: bookinfo
spec:
  host: httpbin.org
  trafficPolicy:
    tls:
      mode: SIMPLE
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ratings-to-httpbin
  namespace: bookinfo
spec:
  targetRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: httpbin.org
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/bookinfo/sa/bookinfo-ratings"
EOF
  ok "ServiceEntry + AuthorizationPolicy applied"

  sleep 5

  step "Test: ratings should reach httpbin.org (ALLOW path)"
  local ratings_pod
  ratings_pod="$(kubectl --context "$CLUSTER1" get pod -l app=ratings -n bookinfo \
                  -o jsonpath='{.items[0].metadata.name}')"
  if kubectl --context "$CLUSTER1" exec -n bookinfo "$ratings_pod" -- \
       curl -s -o /dev/null -w '%{http_code}' httpbin.org/get 2>/dev/null \
       | grep -q '200'; then
    ok "ratings → httpbin.org HTTP 200"
  else
    warn "ratings → httpbin.org didn't return 200 (may be slow on first call)"
  fi

  step "Test: reviews should be BLOCKED (deny path)"
  local reviews_pod
  reviews_pod="$(kubectl --context "$CLUSTER1" get pod -l app=reviews -n bookinfo \
                  -o jsonpath='{.items[0].metadata.name}')"
  local out
  out="$(kubectl --context "$CLUSTER1" exec -n bookinfo "$reviews_pod" -- \
          curl -sv httpbin.org/get 2>&1 || true)"
  if echo "$out" | grep -qE 'RBAC|403|denied'; then
    ok "reviews → httpbin.org BLOCKED (RBAC / 403)"
  else
    warn "reviews call didn't show RBAC denial — output: $(echo "$out" | tail -3)"
  fi
}

case "$SCOPE" in
  all)  preflight; lab0; lab1; lab2; lab3 ;;
  lab0) preflight; lab0 ;;
  lab1) preflight; lab1 ;;
  lab2) preflight; lab2 ;;
  lab3) preflight; lab3 ;;
  *) die "unknown scope '$SCOPE' — use: all | lab0 | lab1 | lab2 | lab3" ;;
esac

printf '\n══════════════════════════════════════════════════════════════════════\n'
printf ' Lab run complete (%s). Health check next:\n' "$SCOPE"
printf '   ./scripts/health-check.sh\n'
printf '══════════════════════════════════════════════════════════════════════\n'

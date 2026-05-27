#!/usr/bin/env bash
# health-check.sh — validate the cloud-connectivity lab state on top of the
# agentgw-multi-cluster-kind standup. Adaptive: only checks for things that
# are present (LAB 2 / LAB 3 artefacts are optional and may not have been
# deployed yet).
#
# Always checks: the standup is green + bookinfo + ingress (LAB 0) if present.
# Conditionally checks: waypoint (LAB 2), egress (LAB 3) if those exist.
#
# Usage:
#   ./scripts/health-check.sh
#   ./scripts/health-check.sh lab0    # only LAB 0 prereq
#   ./scripts/health-check.sh lab2    # only LAB 2 state
#   CLUSTER1=kind-east-ag CLUSTER2=kind-west-ag ./scripts/health-check.sh

set -uo pipefail

CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"
SCOPE="${1:-all}"

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { printf '   \033[32m✓\033[0m %s\n' "$*";  PASS=$((PASS+1)); }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$*";  FAIL=$((FAIL+1)); FAILED_NAMES+=("$*"); }
skip() { printf '   \033[33m∼\033[0m %s\n' "$*"; }
step() { printf '\n══> %s\n' "$*"; }

# Standup health is the precondition for everything below. Delegate to that
# script if available so we don't duplicate logic.
check_standup() {
  step "Standup precondition"
  local standup_hc
  standup_hc="$(dirname "$0")/../../agentgw-multi-cluster-kind/scripts/health-check.sh"
  if [[ -x "$standup_hc" ]]; then
    if "$standup_hc" >/dev/null 2>&1; then
      ok "standup health-check.sh PASS"
    else
      bad "standup health-check.sh FAIL — fix the standup first"
    fi
  else
    skip "standup health-check.sh not found at $standup_hc (re-rsync the repo)"
  fi
}

# LAB 0 — bookinfo + ingress. Skip silently if bookinfo namespace doesn't
# exist on east (it's the gate for this lab having been deployed at all).
check_lab0() {
  step "LAB 0 — Bookinfo + agentgateway ingress"
  if ! kubectl --context="$CLUSTER1" get ns bookinfo >/dev/null 2>&1; then
    skip "LAB 0 not deployed (no bookinfo namespace on $CLUSTER1)"
    return
  fi

  for ctx in "$CLUSTER1" "$CLUSTER2"; do
    if kubectl --context="$ctx" -n bookinfo get deploy productpage-v1 >/dev/null 2>&1; then
      ok "$ctx — productpage-v1 deployed"
    else
      bad "$ctx — productpage-v1 missing"
    fi
    label="$(kubectl --context="$ctx" -n bookinfo get svc productpage \
              -o jsonpath='{.metadata.labels.solo\.io/service-scope}' 2>/dev/null || true)"
    if [[ "$label" == "global" ]]; then
      ok "$ctx — productpage Service labeled solo.io/service-scope=global"
    else
      bad "$ctx — productpage solo.io/service-scope='${label:-<unset>}' (expected 'global')"
    fi
  done

  # shared global hostname seen by istioctl
  if istioctl --context="$CLUSTER1" multicluster check 2>&1 | grep -q "1 globally shared service"; then
    ok "$CLUSTER1 — 1 globally shared service registered"
  else
    bad "$CLUSTER1 — no globally shared service (istioctl multicluster check)"
  fi

  # ingress Gateway
  prog="$(kubectl --context="$CLUSTER1" -n bookinfo get gateway bookinfo-gateway \
            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  if [[ "$prog" == "True" ]]; then
    ok "$CLUSTER1 — bookinfo-gateway Programmed=True"
  else
    bad "$CLUSTER1 — bookinfo-gateway Programmed='${prog:-missing}'"
  fi

  # HTTPRoute parent / backend
  if kubectl --context="$CLUSTER1" -n bookinfo get httproute productpage >/dev/null 2>&1; then
    ok "$CLUSTER1 — HTTPRoute 'productpage' present"
  else
    bad "$CLUSTER1 — HTTPRoute 'productpage' missing"
  fi
}

# LAB 2 — waypoint Gateway + namespace label + reviews HTTPRoute.
check_lab2() {
  step "LAB 2 — enterprise-agentgateway-waypoint"
  if ! kubectl --context="$CLUSTER1" -n bookinfo get gateway agw-waypoint >/dev/null 2>&1; then
    skip "LAB 2 not deployed (no agw-waypoint Gateway)"
    return
  fi
  prog="$(kubectl --context="$CLUSTER1" -n bookinfo get gateway agw-waypoint \
            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  [[ "$prog" == "True" ]] && ok "agw-waypoint Programmed=True" || bad "agw-waypoint Programmed='$prog'"

  use_wp="$(kubectl --context="$CLUSTER1" get ns bookinfo \
             -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null || true)"
  [[ "$use_wp" == "agw-waypoint" ]] && ok "bookinfo ns istio.io/use-waypoint=agw-waypoint" \
    || bad "bookinfo ns istio.io/use-waypoint='${use_wp:-<unset>}'"

  if kubectl --context="$CLUSTER1" -n bookinfo get httproute reviews >/dev/null 2>&1; then
    ok "reviews HTTPRoute applied"
  else
    skip "reviews HTTPRoute not applied yet"
  fi
}

# LAB 3 — egress namespace + egress-gateway + ServiceEntry + AuthorizationPolicy.
check_lab3() {
  step "LAB 3 — egress gateway"
  if ! kubectl --context="$CLUSTER1" get ns istio-egress >/dev/null 2>&1; then
    skip "LAB 3 not deployed (no istio-egress namespace)"
    return
  fi
  prog="$(kubectl --context="$CLUSTER1" -n istio-egress get gateway egress-gateway \
            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  [[ "$prog" == "True" ]] && ok "egress-gateway Programmed=True" || bad "egress-gateway Programmed='$prog'"

  if kubectl --context="$CLUSTER1" -n bookinfo get serviceentry httpbin.org >/dev/null 2>&1; then
    ok "ServiceEntry httpbin.org present"
  else
    bad "ServiceEntry httpbin.org missing"
  fi
  if kubectl --context="$CLUSTER1" -n bookinfo get authorizationpolicy ratings-to-httpbin >/dev/null 2>&1; then
    ok "AuthorizationPolicy ratings-to-httpbin present"
  else
    bad "AuthorizationPolicy ratings-to-httpbin missing"
  fi
}

case "$SCOPE" in
  all)  check_standup; check_lab0; check_lab2; check_lab3 ;;
  lab0) check_lab0 ;;
  lab2) check_lab2 ;;
  lab3) check_lab3 ;;
  standup) check_standup ;;
  *) printf 'Unknown scope: %s — use all|standup|lab0|lab2|lab3\n' "$SCOPE" >&2; exit 2 ;;
esac

printf '\n──────────────────────────────────────────────────────────────────────\n'
if (( FAIL == 0 )); then
  printf ' \033[32m✓ HEALTH CHECK PASSED\033[0m — %d checks green\n' "$PASS"
  printf '──────────────────────────────────────────────────────────────────────\n'
  exit 0
else
  printf ' \033[31m✗ HEALTH CHECK FAILED\033[0m — %d passed, %d failed\n' "$PASS" "$FAIL"
  printf '──────────────────────────────────────────────────────────────────────\n'
  printf 'Failed checks:\n'; for f in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi

#!/usr/bin/env bash
# health-check.sh — validate the Solo Istio Ambient + agentgateway standup
# (east-ag + west-ag) is healthy.
#
# Each check prints PASS/FAIL and we keep going to the end so you see the
# full picture in one shot. Exit 0 if everything passed, 1 otherwise.
#
# Usage:
#   ./scripts/health-check.sh
#   CLUSTER1=kind-east-ag CLUSTER2=kind-west-ag ./scripts/health-check.sh

set -uo pipefail   # NOT -e — we want all checks to run

CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { printf '   \033[32m✓\033[0m %s\n' "$*";  PASS=$((PASS+1)); }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$*";  FAIL=$((FAIL+1)); FAILED_NAMES+=("$*"); }
step() { printf '\n══> %s\n' "$*"; }
info() { printf '   ▸ %s\n' "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || { bad "$1 not installed"; return 1; }; }

# Run a command silently — pass / fail based on exit code.
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

# Run a command, capture stdout — pass if stdout matches the expected regex.
check_grep() {
  local label="$1" pattern="$2"; shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if echo "$out" | grep -qE "$pattern"; then ok "$label"; else bad "$label  (expected /$pattern/, got: $(echo "$out" | head -1))"; fi
}

# ── tooling on this host ────────────────────────────────────────────────────
step "Local tooling"
require kind && ok "kind on PATH"
require kubectl && ok "kubectl on PATH"
require istioctl && ok "istioctl on PATH"

# ── kind clusters exist ─────────────────────────────────────────────────────
step "kind clusters"
for c in "${CLUSTER1#kind-}" "${CLUSTER2#kind-}"; do
  check "kind cluster '$c' exists" bash -c "kind get clusters | grep -qx '$c'"
done

# ── workload pods ───────────────────────────────────────────────────────────
step "Pods Running (no CrashLoopBackOff / Error / Pending)"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  for ns in istio-system istio-eastwest agentgateway-system; do
    bad_pods="$(kubectl --context="$ctx" -n "$ns" get pods --no-headers 2>/dev/null \
                  | awk '$3 != "Running" && $3 != "Completed" {print $1":"$3}' || true)"
    if [[ -z "$bad_pods" ]]; then
      ok "$ctx / $ns — all pods Running"
    else
      bad "$ctx / $ns — unhealthy: $bad_pods"
    fi
  done
done

# ── east-west Gateways programmed ───────────────────────────────────────────
step "East-west Gateways"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  prog="$(kubectl --context="$ctx" -n istio-eastwest get gateway istio-eastwest \
            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  if [[ "$prog" == "True" ]]; then
    ok "$ctx — istio-eastwest Gateway Programmed=True"
  else
    bad "$ctx — istio-eastwest Gateway Programmed='$prog'"
  fi
done

# ── agentgateway controller image ───────────────────────────────────────────
step "agentgateway controller image"
for ctx in "$CLUSTER1" "$CLUSTER2"; do
  img="$(kubectl --context="$ctx" -n agentgateway-system get deploy \
          -o jsonpath='{.items[*].spec.template.spec.containers[*].image}' 2>/dev/null \
          | tr ' ' '\n' | grep -E 'controller|enterprise-agentgateway' | head -1 || true)"
  if [[ -n "$img" ]]; then
    info "$ctx — controller image: $img"
    ok "$ctx — agentgateway controller deployed"
  else
    bad "$ctx — no agentgateway controller image found"
  fi
done

# ── multicluster peering (the green-light check) ────────────────────────────
step "Multicluster peering (istioctl multicluster check)"
mcc="$(istioctl --context="$CLUSTER1" multicluster check 2>&1 || true)"
check_grep "Peers Check: all clusters connected" \
  "Peers Check: all clusters connected" echo "$mcc"
check_grep "Connected to ${CLUSTER2#kind-}" \
  "Connected to ${CLUSTER2#kind-}" echo "$mcc"

# ── summary ─────────────────────────────────────────────────────────────────
printf '\n──────────────────────────────────────────────────────────────────────\n'
if (( FAIL == 0 )); then
  printf ' \033[32m✓ HEALTH CHECK PASSED\033[0m — %d checks, all green\n' "$PASS"
  printf '──────────────────────────────────────────────────────────────────────\n'
  exit 0
else
  printf ' \033[31m✗ HEALTH CHECK FAILED\033[0m — %d passed, %d failed\n' "$PASS" "$FAIL"
  printf '──────────────────────────────────────────────────────────────────────\n'
  printf 'Failed checks:\n'
  for f in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi

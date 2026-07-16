#!/usr/bin/env bash
# e2e.sh — runs the whole lab end to end and asserts the report says what the
# README promises. Safe to re-run; tears nothing down (use kind delete cluster
# --name port-audit for that).
#
# Runs the traffic for a soak period (default 5 minutes, override SOAK=seconds)
# and then asserts, for svc-b, that report.json shows:
#   used_ports               == [8080, 8081, 8082, 9090, 9091, 9092]   (6 used)
#   authz_allowed_never_used == [8083, 8084, 9093, 9094]               (4 allowed, never used)
#   unused_ports             == [7070, 8083, 8084, 9093, 9094]         (exposed, never used)
#   denied_attempts          == [7070]         (after the deliberate probe)
#   nodes_reporting          has both workers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require jq

step "1/6 Cluster + mesh"
bash "$SCRIPT_DIR/setup-cluster.sh"

step "2/6 Building the collector image + pre-loading app images"
bash "$SCRIPT_DIR/build-collector.sh"
for img in python:3.12-alpine curlimages/curl:8.14.1 alpine/k8s:1.33.4; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull --quiet "$img" >/dev/null
  tar="$(mktemp)"; docker save --platform "$KIND_PLATFORM" "$img" -o "$tar"
  kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null; rm -f "$tar"
  log "loaded $img"
done
ok "collector image built; app images loaded"

step "3/6 App + policy + audit stack"
kapply "$LAB_ROOT/yaml/10-app/"
kapply "$LAB_ROOT/yaml/20-policy/"
kapply "$LAB_ROOT/yaml/30-audit/"
wait_deploy "$NS_APP" svc-b
wait_deploy "$NS_APP" svc-a
# Available is not enough: a rolling update blocked by scheduling keeps the
# OLD pods serving and Available=True while the new template never lands.
# rollout status waits for the new ReplicaSet specifically.
kc -n "$NS_APP" rollout status deploy/svc-b --timeout=180s >/dev/null
kc -n "$NS_APP" rollout status deploy/svc-a --timeout=180s >/dev/null
# And prove the server actually binds all eleven ports before judging usage.
# (Skip pods that are terminating — the label selector still matches the old
# ReplicaSet's pods for a few seconds after a successful rollout.)
for pod in $(kc -n "$NS_APP" get pods -l app=svc-b -o json \
               | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name'); do
  n="$(kc -n "$NS_APP" logs "pod/$pod" | grep -c '^listening on' || true)"
  [[ "$n" -eq 11 ]] || die "pod/$pod listens on $n ports, want 11 — rollout did not land"
done
kc -n "$NS_AUDIT" rollout status daemonset/port-audit-collector --timeout=120s >/dev/null
# Start the observation window clean. Order matters: kill ALL collector pods
# first (a rolling restart leaves the other node's old pod alive long enough
# to patch its stale state into the fresh ConfigMap, and the new pods seed
# from their own key on start), then recreate the ConfigMap, then bring the
# collectors back.
kc -n "$NS_AUDIT" delete daemonset port-audit-collector --ignore-not-found >/dev/null
end=$(( $(date +%s) + 120 ))
while [[ -n "$(kc -n "$NS_AUDIT" get pods -l app=port-audit-collector -o name 2>/dev/null)" ]]; do
  [[ $(date +%s) -ge $end ]] && die "old collector pods did not terminate within 2m"
  sleep 3
done
kc -n "$NS_AUDIT" delete configmap port-audit-report --ignore-not-found >/dev/null
kapply "$LAB_ROOT/yaml/30-audit/00-namespace-and-report.yaml"
kapply "$LAB_ROOT/yaml/30-audit/30-collector-daemonset.yaml"
kc -n "$NS_AUDIT" rollout status daemonset/port-audit-collector --timeout=120s >/dev/null
ok "svc-a, svc-b (2 replicas across both workers) and the audit stack are running (fresh window)"

step "4/6 Deliberate denied probe (svc-a → svc-b:7070, not in the policy)"
sleep 10   # let ztunnel program the just-applied policy before probing
if kc -n "$NS_APP" exec deploy/svc-a -- curl -s --max-time 3 "http://svc-b:7070/" >/dev/null 2>&1; then
  die "svc-b:7070 was reachable — the AuthorizationPolicy is not enforcing"
fi
ok "7070 denied by ztunnel, as intended"

step "5/6 Soaking: svc-a traffic runs for ${SOAK:-300}s before the report is judged"
# The report is cumulative, but a real audit is "observed over a window", so
# give the window real length: five minutes of the 6 used ports being hit
# every 2s while the 4 unused ones stay silent.
sleep "${SOAK:-300}"
end=$(( $(date +%s) + 300 ))
report=""
while true; do
  report="$(kc -n "$NS_AUDIT" get configmap port-audit-report \
    -o jsonpath='{.data.report\.json}' 2>/dev/null || true)"
  if [[ -n "$report" ]] && \
     [[ "$(echo "$report" | jq '[.services[] | select(.service == "svc-b") | .used_ports] | first // [] | length')" -ge 6 ]] && \
     [[ "$(echo "$report" | jq '[.services[] | select(.service == "svc-b") | .denied_attempts] | first // [] | length')" -ge 1 ]]; then
    break
  fi
  [[ $(date +%s) -ge $end ]] && { echo "$report" | jq . >&2 || true; die "report did not converge within 5m after the soak"; }
  sleep 10
done
ok "report.json present and populated after the soak"

step "6/6 Asserting the report"
fail=0
assert_eq() { # desc, jq expr, expected
  local got; got="$(echo "$report" | jq -c "$2")"
  if [[ "$got" == "$3" ]]; then ok "$1: $got"; else warn "$1: got $got, want $3"; fail=1; fi
}
svcb='.services[] | select(.service == "svc-b")'
assert_eq "used_ports (6 used)"      "[$svcb.used_ports] | first"               '[8080,8081,8082,9090,9091,9092]'
assert_eq "authz_allowed_never_used (4 unused)" \
  "[$svcb.authz_allowed_never_used] | first" '[8083,8084,9093,9094]'
assert_eq "unused_ports (exposed, never used)" \
  "[$svcb.unused_ports] | first"             '[7070,8083,8084,9093,9094]'
assert_eq "denied_attempts"          "[$svcb.denied_attempts] | first"          '[7070]'
assert_eq "both workers reporting"   '.nodes_reporting | sort | length'          '2'
assert_eq "over_provisioned flag"    "[$svcb.over_provisioned] | first"          'true'

echo
echo "── report.json ──────────────────────────────────────────────"
echo "$report" | jq .
[[ $fail -eq 0 ]] || die "assertions failed"
ok "E2E PASSED"

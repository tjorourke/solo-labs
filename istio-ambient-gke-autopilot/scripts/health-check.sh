#!/usr/bin/env bash
# health-check.sh — prove Istio ambient actually enforces something on Autopilot,
# rather than just having its pods Running.
#
# Six checks, in order of what they prove:
#
#   1. The privileged DaemonSets are admitted and healthy. On Autopilot that is
#      only possible through a WorkloadAllowlist, so it is the first thing to
#      assert and the thing that used to be impossible.
#   2. Workloads are captured. istio-cni stamps ambient.istio.io/redirection on
#      every pod it enrols. Without it a pod is in an "ambient" namespace and
#      still completely unmeshed.
#   3. mTLS is real. ztunnel reports the peer's SPIFFE identity on the
#      connection, which is what makes identity-based policy meaningful.
#   4. L4 policy: ztunnel allows one ServiceAccount and denies another, on
#      identity, not IP.
#   5. L7 policy: the waypoint denies one HTTP method while leaving others
#      working. This is the part ztunnel alone cannot do.
#   6. Removing the policy restores traffic, so the deny was the policy and not
#      something incidentally broken.
#
# On debugging: pods admitted through a WorkloadAllowlist carry
# autopilot.gke.io/no-connect, and Autopilot's autogke-no-pod-connect-limitation
# then refuses exec and port-forward into them. So istioctl ztunnel-config and
# istioctl proxy-config cannot be used against ztunnel here. Every check below
# works from logs, from metrics scraped by another pod, and from traffic
# behaviour instead.
set -uo pipefail

NS="${NS:-my-app}"
WP="${WP:-my-waypoint}"
YAML_DIR="${YAML_DIR:-../yaml/test}"
SVC="health-server.${NS}.svc.cluster.local:8080"

PASS=0; FAIL=0
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '\033[33mwarn\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

kubectl version -o json >/dev/null 2>&1 || die "cannot reach the cluster"

client_pod() {
  kubectl -n "$NS" get pod -l "app=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# HTTP status from one client identity to the health server. Prints the code, or
# 000 when the connection itself was refused, which is what an L4 deny looks
# like. curl writes 000 itself on a failed connection, so do not add a fallback
# echo as well or the two concatenate into "000000".
curl_status() {
  local app="$1" method="${2:-GET}" path="${3:-/}" out
  out="$(kubectl -n "$NS" exec "$(client_pod "$app")" -c client -- \
    curl -s -o /dev/null -w '%{http_code}' -m 10 -X "$method" \
    "http://${SVC}${path}" 2>/dev/null)"
  echo "${out:-000}"
}

step "1. Privileged DaemonSets admitted and healthy"
for d in istio-cni-node ztunnel; do
  R="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.numberReady}' 2>/dev/null)"
  W="$(kubectl -n istio-system get ds "$d" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
  [[ -n "$R" && "$R" == "$W" && "$R" -gt 0 ]] \
    && ok "$d $R/$W ready" \
    || bad "$d is ${R:-0}/${W:-0}"
done

step "2. Workloads captured by istio-cni"
kubectl -n "$NS" get pods \
  -o custom-columns='POD:.metadata.name,REDIRECTION:.metadata.annotations.ambient\.istio\.io/redirection'
UNCAPTURED="$(kubectl -n "$NS" get pods -o json 2>/dev/null \
  | grep -c '"ambient.istio.io/redirection": "enabled"')"
[[ "${UNCAPTURED:-0}" -gt 0 ]] \
  && ok "$UNCAPTURED pod(s) carry ambient.istio.io/redirection=enabled" \
  || bad "no pod in $NS is captured; the namespace label alone is not enough"

step "3. mTLS: ztunnel reports peer SPIFFE identities"
# Scraped from another pod, because exec into ztunnel is refused on Autopilot.
ZIP="$(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)"
CP="$(client_pod health-allowed)"
curl_status health-allowed >/dev/null 2>&1   # generate one connection first
PRINCIPALS="$(kubectl -n "$NS" exec "$CP" -c client -- \
  curl -s -m 10 "http://${ZIP}:15020/metrics" 2>/dev/null \
  | grep -oE '(source|destination)_principal="[^"]*"' | sort -u)"
if [[ -n "$PRINCIPALS" ]]; then
  echo "$PRINCIPALS" | sed 's/^/     /'
  ok "peer identities present on the connection"
else
  bad "no source/destination principals in ztunnel metrics"
fi

step "4. L4 policy, enforced by ztunnel"
BASE_A="$(curl_status health-allowed)"; BASE_D="$(curl_status health-denied)"
echo "     baseline: allowed=$BASE_A denied=$BASE_D"
kubectl apply -f "$YAML_DIR/04-l4-policy.yaml" >/dev/null
sleep 8
L4_A="$(curl_status health-allowed)"; L4_D="$(curl_status health-denied)"
[[ "$L4_A" == "200" && "$L4_D" == "000" ]] \
  && ok "allowed=$L4_A denied=$L4_D, and 000 means the connection was refused" \
  || bad "expected allowed=200 denied=000, got allowed=$L4_A denied=$L4_D"

step "5. L7 policy, enforced by the waypoint"
kubectl -n "$NS" label service health-server "istio.io/use-waypoint=$WP" --overwrite >/dev/null
kubectl apply -f "$YAML_DIR/05-l7-policy.yaml" >/dev/null
sleep 10
GETC="$(curl_status health-allowed GET)"; DELC="$(curl_status health-allowed DELETE)"
[[ "$GETC" == "200" && "$DELC" == "403" ]] \
  && ok "GET=$GETC DELETE=$DELC, and 403 with the connection intact means L7 decided" \
  || bad "expected GET=200 DELETE=403, got GET=$GETC DELETE=$DELC"

step "6. Removing the policy restores traffic"
kubectl -n "$NS" delete authorizationpolicy health-l7-deny-methods >/dev/null 2>&1
sleep 8
DEL_AFTER="$(curl_status health-allowed DELETE)"
[[ "$DEL_AFTER" == "200" ]] \
  && ok "DELETE=$DEL_AFTER, so the deny was the policy" \
  || bad "expected DELETE=200 after removing the policy, got $DEL_AFTER"

# Leave the cluster as we found it.
kubectl -n "$NS" label service health-server istio.io/use-waypoint- >/dev/null 2>&1
kubectl -n "$NS" delete authorizationpolicy health-l4-allow-one-identity >/dev/null 2>&1

step "Summary"
printf '  passed: %s   failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || die "$FAIL check(s) failed"

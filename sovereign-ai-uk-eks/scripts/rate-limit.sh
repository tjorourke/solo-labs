#!/usr/bin/env bash
# Show the per-identity request cap engage, and prove it is per identity.
#
# yaml/38-rate-limit.yaml caps each JWT subject at 10 model calls a minute, counted in the
# enterprise rate-limiter that ships with agentgateway. This drives one identity past its
# cap (a 429 appears) and then shows a second identity still has its own budget, which is
# what "per identity" means. The model backend may be down (GPU scaled to zero); that is
# fine, the rate-limiter answers before the backend, so an under-limit call is a 503 and an
# over-limit call is a clean 429.
#
#   ./scripts/rate-limit.sh test    hammer as alice (trips 429), then bob (still has budget)
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
GW="$(kubectl --context "$CTX" -n agentgateway-system get svc sovereign-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
[ -n "$GW" ] || { echo "error: gateway LoadBalancer has no hostname yet" >&2; exit 1; }

call() { # call <token>
  curl -sk -o /dev/null -w '%{http_code} ' -m 8 "https://${GW}/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d '{"model":"mistral-small-3.2-24b","messages":[{"role":"user","content":"hi"}]}'
}

case "${1:-test}" in
  test)
    alice="$("$HERE/keycloak.sh" token alice 2>/dev/null | tail -1)"
    bob="$("$HERE/keycloak.sh"   token bob   2>/dev/null | tail -1)"
    echo "== 15 model calls as alice (cap is 10/min per identity) — 429 once the bucket empties"
    printf 'alice: '; for i in $(seq 1 15); do call "$alice"; done; echo
    echo "== bob, right after — his own bucket, so no 429 (503 = auth+limit passed, model is down)"
    printf 'bob:   '; for i in 1 2 3; do call "$bob"; done; echo
    ;;
  *) echo "usage: $0 test"; exit 1 ;;
esac

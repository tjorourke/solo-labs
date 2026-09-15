#!/usr/bin/env bash
# The refusals. Identity-based routing is an access control, so what it refuses is as much
# the result as what it routes.
#
#   ./scripts/10-test-negative.sh
#   SKIP_OUTAGE=1 ./scripts/10-test-negative.sh    # leave out the two fail-closed cases
#
# N1 and N2 must be refused by the gateway before OPA is called, and the script proves that
# by counting OPA decisions. N3 is OPA's own refusal. N4 to N7 are spoofing attempts that
# must change nothing, N5 being the one that matters: restricted data does not leave the
# cluster because a client asked. N8 to N10 pin down what a client may and may not name in
# the body. N11 and N12 take OPA and then the router down and confirm the request is
# refused rather than sent somewhere by default; they restart both and add about a
# minute. Exits non-zero on any miss.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens; gw_up
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
opa_decisions() { kubectl -n "$NS" logs deploy/opa --since-time="$MARK" 2>/dev/null | grep -c '"decision_id"' || true; }
err_msg() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("error",{}).get("message",""))
except Exception: print(open(sys.argv[1]).read()[:60])' "$BODY"; }
ok=0; n=0
row() { # row <good 0|1> <what> <evidence>
  n=$((n+1)); ok=$((ok+$1))
  local mark="ok"; [ "$1" = 1 ] || mark="X "
  printf "%-3s %-66s %s %s\n" "N$n" "$2" "$mark" "$3"
}
t() { [ "$1" = "$2" ] && echo 1 || echo 0; }

before=$(opa_decisions)
gw_curl - "$(chat "$BASIC")"
row $(t "$STATUS/$(opa_decisions)" "401/$before") "no token" "$STATUS, OPA not called"
gw_curl "$BADSIG_TOKEN" "$(chat "$BASIC")"
row $(t "$STATUS/$(opa_decisions)" "401/$before") "token signed by a key that is not in the JWKS" "$STATUS, OPA not called"
gw_curl "$UNKNOWN_TOKEN" "$(chat "$BASIC")"
row $(t "$STATUS" 403) "valid token, user not in the entitlement data" "$STATUS $(err_msg)"

gw_curl "$ALICE_TOKEN" "$(chat "$BASIC")" -H 'x-routing-target: self-hosted'
row $(t "$(target)" openai) "alice sends x-routing-target: self-hosted" "target=$(target)"
gw_curl "$CAROL_TOKEN" "$(chat "$BASIC")" -H 'x-routing-target: openai'
row $(t "$(target)" self-hosted) "carol (restricted) sends x-routing-target: openai" "target=$(target)"
gw_curl "$CAROL_TOKEN" "$(chat "$BASIC")" -H 'x-selected-model: code'
row $(t "$(class)" general) "carol sends x-selected-model: code with the basic prompt" "class=$(class)"
gw_curl "$CAROL_TOKEN" "$(chat "$BASIC")" -H 'x-vsr-selected-model: code'
row $(t "$(class)" general) "carol sends x-vsr-selected-model: code with the basic prompt" "class=$(class)"

# What the body may name. A logical class is honoured, because the router treats a name
# it knows as the caller's choice and skips classification; the target is still OPA's.
# Anything else, a real model name included, is refused by the router before any
# backend is called.
gw_curl "$CAROL_TOKEN" "$(chat "$BASIC" code)"
row $(t "$(target)/$(class)/$(resp_model)" self-hosted/code/qwen3-coder-30b) "carol names the class: model: code" "target=$(target) class=$(class) model=$(resp_model)"
gw_curl "$CAROL_TOKEN" "$(chat "$BASIC" gpt-5.4)"
row $(t "$STATUS" 400) "carol names a frontier model: gpt-5.4" "$STATUS $(err_msg)"
gw_curl "$ALICE_TOKEN" "$(chat "$BASIC" qwen3-coder-30b)"
row $(t "$STATUS" 400) "alice names the GPU model: qwen3-coder-30b" "$STATUS $(err_msg)"

if [ -z "${SKIP_OUTAGE:-}" ]; then
  kubectl -n "$NS" scale deploy/opa --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app=opa --timeout=90s >/dev/null 2>&1 || true
  sleep 2
  gw_curl "$CAROL_TOKEN" "$(chat "$BASIC")"
  row $(t "$STATUS" 403) "OPA is down" "$STATUS $(err_msg)"
  kubectl -n "$NS" scale deploy/opa --replicas=1 >/dev/null
  kubectl -n "$NS" rollout status deploy/opa --timeout=180s >/dev/null

  kubectl -n "$NS" scale deploy/semantic-router --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=semantic-router --timeout=180s >/dev/null 2>&1 || true
  sleep 2
  gw_curl "$CAROL_TOKEN" "$(chat "$BASIC")"
  row $(t "$STATUS" 500) "the semantic router is down" "$STATUS $(err_msg)"
  kubectl -n "$NS" scale deploy/semantic-router --replicas=1 >/dev/null
  kubectl -n "$NS" wait --for=condition=Available deploy/semantic-router --timeout=900s >/dev/null
  sleep 3
  gw_curl "$CAROL_TOKEN" "$(chat "$BASIC")"
  row $(t "$STATUS/$(class)" 200/general) "both back, carol routes again" "$STATUS target=$(target) class=$(class) model=$(resp_model)"
fi
echo; echo "negative: $ok/$n as expected"
[ "$ok" = "$n" ]

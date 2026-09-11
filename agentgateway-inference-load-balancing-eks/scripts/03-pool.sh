#!/usr/bin/env bash
# Wire the routing path: Gateway, InferencePool, Endpoint Picker, route.
#
#   ./scripts/03-pool.sh
#
# Order matters slightly. The Gateway is applied first so the route has a parent to
# attach to, the pool and its Endpoint Picker second, and the route last, pointing at
# the pool. Apply the route first and it reports a resolution error until the pool
# exists, which is harmless but reads like a failure.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

PROFILE="${1:-default}"

step "Gateway (class $GATEWAY_CLASS)"
kc_apply_tmpl "$LAB_ROOT/yaml/05-gateway.yaml" >/dev/null
ok "Gateway 'inference-gateway' applied"

step "InferencePool '$POOL_RELEASE' + Endpoint Picker (GIE $GIE_VERSION, profile: $PROFILE)"
"$LAB_ROOT/scripts/profile.sh" "$PROFILE"

step "InferenceObjective"
kc apply -f "$LAB_ROOT/yaml/20-inferenceobjective.yaml" >/dev/null
ok "applied"

step "route: HTTPRoute -> InferencePool"
"$LAB_ROOT/scripts/route.sh" pool

step "waiting for the Gateway to program"
kc -n "$NS" wait --for=condition=Programmed gateway/inference-gateway --timeout=300s >/dev/null
ok "Gateway Programmed"

# ── the check that matters ────────────────────────────────────────────────────────────
# failureMode is FailOpen, which is the right setting and also the one that hides a
# broken Endpoint Picker: if the EPP is unreachable the gateway quietly picks an
# endpoint itself and every request still succeeds. The route reports Accepted, the
# Gateway reports Programmed, the pods are Running, and the lab measures round-robin
# while claiming to measure scheduling.
#
# The only honest proof is the access log field the gateway writes when it used the
# picker's answer: inferencepool.selected_endpoint. If it is absent, the picker was not
# consulted.
step "proving the Endpoint Picker is actually being consulted"
kc -n "$NS" exec deploy/loadgen -- python3 -c "
import json,urllib.request
body=json.dumps({'model':'$MODEL_NAME','messages':[{'role':'user','content':'ping'}],'max_tokens':1}).encode()
req=urllib.request.Request('http://inference-gateway.$NS.svc.cluster.local/v1/chat/completions',
                           data=body, headers={'Content-Type':'application/json'})
urllib.request.urlopen(req, timeout=120).read()
print('request ok')
" || die "the gateway did not serve a request — check: kc -n $NS get gateway,httproute,inferencepool"

sleep 2
if kc -n "$NS" logs -l gateway.networking.k8s.io/gateway-name=inference-gateway --tail=20 2>/dev/null \
     | grep -q 'inferencepool.selected_endpoint='; then
  ok "the picker chose the endpoint (inferencepool.selected_endpoint is in the access log)"
else
  warn "no inferencepool.selected_endpoint in the access log."
  warn "The request succeeded, so this is FailOpen doing its job: the picker was not"
  warn "consulted and the gateway fell back to choosing an endpoint itself."
  warn "Check the EPP:  kc -n $NS get pods -l inferencepool=$POOL_RELEASE-epp"
  warn "               kc -n $NS logs deploy/$POOL_RELEASE-epp --tail=50"
  die "the Endpoint Picker is not in the path; nothing measured from here would mean anything"
fi

step "ready"
kc -n "$NS" get gateway,httproute,inferencepool

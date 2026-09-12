#!/usr/bin/env bash
# check.sh: every containment claim this part makes, executed.
#
#   1. Tools    contained-tools serves exactly four read tools to sre-contained and none
#               to another identity; the direct route to kagent-tools is reset
#   2. Egress   the contained pod cannot reach api.anthropic.com itself, and reaches its
#               model through the waypoint (the agent answers)
#   3. A2A      sre-caller's delegated turn is answered by sre-contained; sre-other's
#               call to sre-contained is refused at its waypoint
#   4. Edge     the published route refuses a call with no token and serves the four
#               read tools with one
#   5. Audit    this part's published route refuses a call with no token; every other
#               published route is listed with its verdict
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
QUESTION="Which pods in $SRE_NS are unhealthy, and why?"
fail(){ die "check failed: $*"; }

step "1. Tools: one identity, four read tools"
A="$(bash "$SCRIPT_DIR/probe-as.sh" sre-contained)"; echo "   $A"
[[ "$A" == *"4 tool(s): k8s_describe_resource k8s_get_events k8s_get_pod_logs k8s_get_resources" ]] || fail "sre-contained did not get the four read tools"
B="$(bash "$SCRIPT_DIR/probe-as.sh" sre-other)"; echo "   $B"
[[ "$B" == *"0 tool(s)"* ]] || fail "sre-other got tools from contained-tools"
ok "contained-tools: sre-contained 4, sre-other 0"

step "2. Egress: no route out except the gateways"
POD="$(kc -n "$NS" get pod -l app.kubernetes.io/name=sre-contained -o name | head -1)"
[[ -n "$POD" ]] || fail "no sre-contained pod"
OUT="$(kc -n "$NS" exec "$POD" -- python3 -c '
import urllib.request
for u in ["https://api.anthropic.com/", "http://kagent-tools.kagent:8084/mcp", "http://sre-model.kagent.svc.cluster.local/"]:
    try:
        r = urllib.request.urlopen(u, timeout=6); print(u, "reached", r.status)
    except urllib.error.HTTPError as e:
        print(u, "reached", e.code)
    except Exception as e:
        print(u, "refused", type(e).__name__)' 2>/dev/null)"
echo "$OUT" | sed 's/^/   /'
echo "$OUT" | grep -q "api.anthropic.com/ refused" || fail "the pod reached api.anthropic.com directly"
echo "$OUT" | grep -q "kagent-tools.kagent:8084/mcp refused" || fail "the pod reached kagent-tools directly"
echo "$OUT" | grep -q "sre-model.kagent.svc.cluster.local/ reached" || fail "the pod cannot reach its model waypoint"
ok "direct routes refused, the model waypoint answers"

step "3. A2A: sre-caller may call sre-contained, sre-other may not"
controller_pf
CALLER="$(bash "$PART1/scripts/ask.sh" sre-caller "$QUESTION")"
echo "$CALLER" | sed 's/^/   /' | head -12
echo "$CALLER" | grep -q "kagent__NS__sre_contained" || fail "sre-caller did not delegate to sre-contained"
echo "$CALLER" | grep -qi "healthy" || fail "sre-caller returned no report"
OTHER="$(bash "$PART1/scripts/ask.sh" sre-other "$QUESTION")"
echo "$OTHER" | sed 's/^/   /' | tail -4
echo "$OTHER" | grep -q "403" || fail "sre-other was not refused by sre-contained's waypoint"
ok "delegation allowed for sre-caller, refused for sre-other"

step "4. Edge: the published route needs a token"
EDGE="$(bash "$SCRIPT_DIR/call-edge.sh")"; echo "$EDGE" | sed 's/^/   /'
echo "$EDGE" | grep -q "no token          → HTTP 401" || fail "the edge route answered without a token"
echo "$EDGE" | grep -q "4 tool(s): k8s_describe_resource k8s_get_events k8s_get_pod_logs k8s_get_resources" || fail "the edge route did not serve the four read tools with a token"
ok "401 without a token, four read tools with one"

step "5. Audit: this part's published route is closed, and the rest is reported"
AUDIT="$(bash "$SCRIPT_DIR/audit-endpoints.sh")"; echo "$AUDIT" | sed 's/^/   /'
echo "$AUDIT" | grep -q "^  contained-tools\..*closed (HTTP 401" || fail "contained-tools is published without a working JWT policy"
ok "contained-tools is closed without a token; open routes above, if any, belong to other workloads on this cluster"

printf '\n' >&2; ok "all five containment checks passed"

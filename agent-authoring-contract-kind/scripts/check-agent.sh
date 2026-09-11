#!/usr/bin/env bash
# check-agent.sh <agent>: the four checks every part of the series ends with.
#
#   1. Ready      the agent card is served, so kagent marks the agent Ready
#   2. Stored     a turn through the controller leaves a task in the session store,
#                 with the question first and the answer last (what the UI draws)
#   3. Gateway    the agent's identity gets exactly the four read tools through the
#                 waypoint, and is reset when it goes to kagent-tools directly
#   4. Identity   the waypoint saw the agent's own SPIFFE identity on the turn
#
# Exits non-zero on the first failure. Check 3 runs from a throwaway pod with the
# agent's service account, so it works for agents whose image has no shell tools.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
AGENT="${1:?usage: check-agent.sh <agent>}"
QUESTION="Which pods in $SRE_NS are unhealthy, and why?"
fail(){ die "check failed: $*"; }

step "1. Ready: $AGENT serves its agent card"
[[ "$(kc -n "$NS" get agent "$AGENT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]] \
  || fail "agent $AGENT is not Ready"
agent_pf "$AGENT"
CARD="$(curl -s -m 5 "$AGENT_URL/.well-known/agent-card.json")"
echo "$CARD" | python3 -c 'import json,sys; c=json.load(sys.stdin); print("   name=%s streaming=%s skills=%s" % (c["name"], c.get("capabilities",{}).get("streaming"), [s["id"] for s in c.get("skills",[])]))' \
  || fail "no agent card at $AGENT_URL/.well-known/agent-card.json"
ok "Ready, card served"

step "2. Stored: a turn lands in the session store"
controller_pf
SESSION="$(open_session "$AGENT" "check: $QUESTION")"
[[ -n "$SESSION" ]] || fail "could not open a session"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# ask.sh prints its two header lines and a blank line before the trace and the answer.
ASK_SESSION="$SESSION" bash "$SCRIPT_DIR/ask.sh" "$AGENT" "$QUESTION" | tail -n +4 | sed 's/^/   /'
COUNT="$(task_count "$SESSION")"
[[ "$COUNT" -ge 1 ]] || fail "GET /api/sessions/$SESSION/tasks returned $COUNT tasks; the UI would show an empty chat"
ROLES="$(ccurl -m 20 "$CONTROLLER_URL/api/sessions/$SESSION/tasks" | python3 -c '
import json,sys; d=json.load(sys.stdin); t=d.get("data",d); t=t.get("tasks",t) if isinstance(t,dict) else t
h=t[-1].get("history",[]); print(" ".join(m.get("role","?") for m in h))')"
echo "   session $SESSION: $COUNT task(s); history roles: $ROLES"
[[ "$ROLES" == user* && "$ROLES" == *agent ]] || fail "task history must start with the user and end with the agent, got: $ROLES"
ok "task stored, history user → agent"

step "3. Gateway: tools only through the waypoint, as $AGENT"
PROBE="probe-$AGENT-$RANDOM"
# A throwaway pod with the agent's service account. Run to completion, then read its
# log: attaching with -i races the container start and sometimes returns nothing.
kc -n "$NS" run "$PROBE" --restart=Never --image=curlimages/curl:8.10.1 --env="NS=$NS" \
  --overrides="{\"spec\":{\"serviceAccountName\":\"$AGENT\"}}" --quiet -- sh -c '
INIT='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'"'"'
H="-H Content-Type:application/json -H Accept:application/json,text/event-stream"
if curl -s -m 5 -o /dev/null $H -d "$INIT" "http://kagent-tools.$NS:8084/mcp" 2>/dev/null; then echo "direct=answered"; else echo "direct=refused"; fi
SID=$(curl -s -m 10 -D - -o /dev/null $H -d "$INIT" "http://sre-tools.$NS.svc.cluster.local/mcp" | tr -d "\r" | awk "tolower(\$1)==\"mcp-session-id:\"{print \$2}")
curl -s -m 10 $H -H "Mcp-Session-Id: $SID" -d '"'"'{"jsonrpc":"2.0","id":2,"method":"tools/list"}'"'"' "http://sre-tools.$NS.svc.cluster.local/mcp" | sed "s/^data: //" | grep "^{" | head -1
' >/dev/null
kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$PROBE" --timeout=120s >/dev/null 2>&1 \
  || warn "probe pod $PROBE did not finish in 120s"
OUT="$(kc -n "$NS" logs "$PROBE" 2>/dev/null || true)"
kc -n "$NS" delete pod "$PROBE" --wait=false >/dev/null 2>&1 || true
DIRECT="$(echo "$OUT" | sed -n 's/^direct=//p')"
TOOLS="$(echo "$OUT" | grep '^{' | python3 -c 'import json,sys; print(" ".join(sorted(t["name"] for t in json.load(sys.stdin)["result"]["tools"])))' 2>/dev/null || true)"
echo "   direct to kagent-tools:8084 → ${DIRECT:-no response}"
echo "   via sre-tools waypoint     → ${TOOLS:-no tools}"
[[ "$DIRECT" == "refused" ]] || fail "the agent reached kagent-tools directly"
[[ "$TOOLS" == "k8s_describe_resource k8s_get_events k8s_get_pod_logs k8s_get_resources" ]] || fail "expected the four read tools, got: $TOOLS"
ok "direct route refused, four read tools via the waypoint"

step "4. Identity: the waypoint saw $AGENT's SPIFFE identity"
TD="$(trust_domain)"
# Captured into a variable rather than piped into grep -q: with pipefail, grep -q exiting
# early would make the pipeline fail because it matched.
SEEN="$(kc -n "$NS" logs -l gateway.networking.k8s.io/gateway-name=sre-tools-waypoint --since-time="$START" --tail=-1 2>/dev/null \
   | grep "src.identity=spiffe://$TD/ns/$NS/sa/$AGENT" || true)"
[[ -n "$SEEN" ]] || fail "no waypoint log line carrying spiffe://$TD/ns/$NS/sa/$AGENT since $START"
echo "$SEEN" | grep -o 'mcp.method.name=[^ ]*\|mcp.tool.name=[^ ]*' | sort | uniq -c | sed 's/^/   /'
ok "identity spiffe://$TD/ns/$NS/sa/$AGENT on the waypoint, $(echo "$SEEN" | wc -l | tr -d ' ') requests"

printf '\n' >&2; ok "all four checks passed for $AGENT (session $SESSION)"

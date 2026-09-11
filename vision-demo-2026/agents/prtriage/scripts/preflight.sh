#!/usr/bin/env bash
# preflight.sh — one command, run ten minutes before you present.
#
# Checks the things that actually break a live demo, in the order they would bite:
# the fixture data, the catalogue, both agents, both MCP paths, model access, policy
# state and trace visibility. Prints one line per check and exits non-zero if anything
# is not ready, so it is safe to put in a terminal and glance at.
#
#   ./scripts/preflight.sh
#   DEMO_REPO=owner/name ./scripts/preflight.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
REPO="${DEMO_REPO:-tjorourke/kagent}"
PAT="${GITHUB_PAT:-${GITHUB_PORTLAB_TOKEN:-}}"
FAIL=0

pass() { printf "  \033[32m✓\033[0m %-34s %s\n" "$1" "${2:-}"; }
fail() { printf "  \033[31m✗\033[0m %-34s %s\n" "$1" "${2:-}"; FAIL=1; }
note() { printf "    %s\n" "$1"; }

echo
echo "  Part 8 preflight  ·  repo ${REPO}"
echo

# ---------------------------------------------------------------- 1. the fixtures
if [ -z "$PAT" ]; then
  fail "fixture data" "no GITHUB_PAT, cannot read the fixtures"
else
  FX="$(python3 - "$PAT" "$REPO" <<'PY' 2>/dev/null
import json,sys,urllib.request
pat,repo=sys.argv[1],sys.argv[2]
def gh(p):
    r=urllib.request.Request("https://api.github.com/repos/%s%s"%(repo,p),
      headers={"Authorization":"Bearer "+pat,"Accept":"application/vnd.github+json"})
    return json.loads(urllib.request.urlopen(r,timeout=30).read())
prs=gh("/pulls?state=open&per_page=100")
t={"READY":0,"draft":0,"on hold":0,"no sign-off":0}
for pr in prs:
    labels={l["name"] for l in pr.get("labels",[])}
    signed=any((c.get("body") or "").strip().upper().startswith("LGTM")
               for c in gh("/issues/%d/comments"%pr["number"]))
    if pr["draft"]: t["draft"]+=1
    elif "do-not-merge/hold" in labels: t["on hold"]+=1
    elif not signed: t["no sign-off"]+=1
    else: t["READY"]+=1
print("%d %d %d %d %d"%(len(prs),t["READY"],t["draft"],t["on hold"],t["no sign-off"]))
PY
)"
  read -r N R D H S <<< "${FX:-0 0 0 0 0}"
  if [ "${N:-0}" = "24" ] && [ "$R" = "2" ] && [ "$D" = "3" ] && [ "$H" = "4" ] && [ "$S" = "15" ]; then
    pass "fixture data" "24 open: 2 ready, 3 draft, 4 held, 15 awaiting"
  else
    fail "fixture data" "got ${N:-?} open: $R ready, $D draft, $H held, $S awaiting (want 24: 2/3/4/15)"
    note "reseed with: RESEED=1 DEMO_REPO=$REPO ./scripts/seed-demo-repo.sh"
  fi
fi

# ---------------------------------------------------------------- 2. the catalogue
if command -v arctl >/dev/null 2>&1; then
  URL="$(arctl get mcpserver github-mcp -o yaml 2>/dev/null | sed -n 's/^ *url: *//p' | head -1)"
  case "$URL" in
    *kagent.svc.cluster.local*) pass "catalogue: approved MCP server" "in-mesh waypoint URL" ;;
    "")                         fail "catalogue: approved MCP server" "not in the catalogue" ;;
    *)                          fail "catalogue: approved MCP server" "points at $URL, not the waypoint" ;;
  esac
  arctl get skill release-report >/dev/null 2>&1 \
    && pass "catalogue: approved skill" "release-report" \
    || fail "catalogue: approved skill" "release-report missing"
  arctl get agent prtriagejava >/dev/null 2>&1 \
    && pass "catalogue: agent prtriagejava" "published" \
    || fail "catalogue: agent prtriagejava" "not published"
  # The release agent is created BY step 6. Absent is the correct pre-demo state, so
  # only complain if it exists and is broken.
  arctl get agent releasejava >/dev/null 2>&1 \
    && note "release agent already published: step 6 will re-apply it, which is fine" \
    || pass "catalogue: agent releasejava" "absent, step 6 creates it"
else
  fail "catalogue" "arctl not on PATH, source demo-scripts/env.sh 8"
fi

# ---------------------------------------------------------------- 3. the platform
prog="$($K -n "$NS" get gateway github-mcp-waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
[ "$prog" = "True" ] && pass "waypoint" "Programmed" || fail "waypoint" "not Programmed (${prog:-absent})"

for ns in agentgateway-system "$NS"; do
  acc="$($K -n "$ns" get enterpriseagentgatewaybackend github-mcp -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  mode="$($K -n "$ns" get enterpriseagentgatewaybackend github-mcp -o jsonpath='{.spec.entMcp.toolMode}' 2>/dev/null)"
  [ "$acc" = "True" ] && pass "backend in $ns" "Accepted, toolMode=${mode:-Standard}" \
                      || fail "backend in $ns" "not Accepted (${acc:-absent})"
done

M1="$($K -n agentgateway-system get enterpriseagentgatewaybackend github-mcp -o jsonpath='{.spec.entMcp.toolMode}' 2>/dev/null)"
M2="$($K -n "$NS" get enterpriseagentgatewaybackend github-mcp -o jsonpath='{.spec.entMcp.toolMode}' 2>/dev/null)"
[ "${M1:-Standard}" = "${M2:-Standard}" ] \
  && pass "the two backends agree" "both ${M1:-Standard}" \
  || fail "the two backends agree" "ingress=$M1 mesh=$M2, the demo would measure the wrong one"

# This runs before you walk on, so it has to assert the state step 1 needs, not merely a
# self-consistent one. Left in CodeSearch after a run, everything below still lines up
# and the opening beat shows two tools instead of ninety three.
if [ "${M1:-Standard}" = "Standard" ] && [ "${M2:-Standard}" = "Standard" ]; then
  pass "toolMode is where step 1 needs it" "Standard on both"
else
  fail "toolMode is where step 1 needs it" "ingress=${M1:-?} mesh=${M2:-?}: step 1 would show 2 tools"
  note "fix: ./agents/prtriage/scripts/reset.sh"
fi

# ---------------------------------------------------------------- 4. the agents
# changelogjava is checked like prtriagejava, not like releasejava: setup deploys it, so
# if it is missing before you present, the refusal beat in step 6 has nothing to refuse.
for a in prtriagejava changelogjava releasejava; do
  exists="$($K -n "$NS" get agent "$a" -o jsonpath='{.metadata.name}' 2>/dev/null)"
  if [ -z "$exists" ]; then
    [ "$a" = "releasejava" ] && pass "agent $a" "not deployed yet, step 6 does it" \
                             || fail "agent $a" "not deployed"
    continue
  fi
  rdy="$($K -n "$NS" get agent "$a" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  pods="$($K -n "$NS" get pods -l "app.kubernetes.io/name=$a" --no-headers 2>/dev/null | grep -c Running)"
  if [ "$rdy" = "True" ] && [ "$pods" = "1" ]; then pass "agent $a" "Ready, 1 pod"
  else fail "agent $a" "Ready=${rdy:-?}, running pods=$pods"; fi
done

# Leftover policies from a previous run are the classic reason a tool list comes back
# short and nobody can see why, so name them rather than leaving it to be discovered.
for ns in agentgateway-system "$NS"; do
  extra="$($K -n "$ns" get enterpriseagentgatewaypolicy -o name 2>/dev/null \
    | sed 's#.*/##' | grep -vE '^(ai-gateway-tracing|github-per-agent)$' | tr '\n' ' ')"
  [ -z "${extra// }" ] && pass "no stray policies in $ns" "" \
                       || fail "stray policy in $ns" "${extra}- delete it or the tool list stays filtered"
done

# ---------------------------------------------------------------- 5. both MCP paths
LB="$($K -n agentgateway-system get gateway ar-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
if [ -n "$LB" ] && [ -x /tmp/mcp.sh ]; then
  n="$(/tmp/mcp.sh "http://github-mcp.${LB}.sslip.io/" tools/list 2>/dev/null | grep -o '"name":"[a-z_]*"' | wc -l | tr -d ' ')"
  want=93; [ "${M1:-Standard}" != "Standard" ] && want=2
  if [ "${n:-0}" = "$want" ]; then pass "ingress MCP path (laptop)" "$n tools, as ${M1:-Standard} expects"
  elif [ "${n:-0}" -gt 0 ]; then fail "ingress MCP path (laptop)" "$n tools, expected $want for ${M1:-Standard}"
  else fail "ingress MCP path (laptop)" "no tools returned"; fi
else
  note "ingress path not checked (/tmp/mcp.sh absent: run the notebook's client cell)"
fi

# Retried, because reset.sh restarts the agent and an agent that has not finished
# re-listing its tools reports the wrong count for a few seconds. A preflight that says
# NOT ready for a reason that fixes itself is worse than no preflight.
inmesh=""
for _ in 1 2 3 4 5; do
inmesh="$($K -n "$NS" exec deploy/prtriagejava -- sh -c '
  U=http://github-mcp.'"$NS"'.svc.cluster.local/
  I='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pre","version":"1"}}}'"'"'
  S=$(wget -qS -O /dev/null --header="Content-Type: application/json" --header="Accept: application/json, text/event-stream" --post-data="$I" $U 2>&1 | grep -i mcp-session-id | awk "{print \$2}")
  wget -qO- --header="Content-Type: application/json" --header="Accept: application/json, text/event-stream" ${S:+--header="Mcp-Session-Id: $S"} \
    --post-data='"'"'{"jsonrpc":"2.0","id":2,"method":"tools/list"}'"'"' $U 2>&1 | grep -o "\"name\":\"[a-z_]*\"" | wc -l' 2>/dev/null | tr -d ' ')"
# The in-mesh count is what the policy leaves for prtriagejava, not the whole catalogue:
# two GitHub tools in Standard, and the two meta tools in a code mode.
  [ "${inmesh:-0}" = "2" ] && break
  sleep 3
done
wantm=2
if [ "${inmesh:-0}" = "$wantm" ]; then pass "in-mesh MCP path (agents)" "$inmesh tools for the triage agent, as the policy allows"
elif [ "${inmesh:-0}" -gt 0 ]; then fail "in-mesh MCP path (agents)" "$inmesh tools, expected $wantm for ${M2:-Standard}"
else fail "in-mesh MCP path (agents)" "the waypoint returned nothing"; fi

# ---------------------------------------------------------------- 6. model access
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')"
  [ "$code" = "200" ] && pass "model access" "Anthropic answered 200" || fail "model access" "Anthropic returned $code"
else
  fail "model access" "ANTHROPIC_API_KEY not set in this shell"
fi
$K -n "$NS" get secret kagent-anthropic >/dev/null 2>&1 \
  && pass "model key in cluster" "Secret/kagent-anthropic" \
  || fail "model key in cluster" "Secret/kagent-anthropic missing"

# ---------------------------------------------------------------- 7. policy state
pol="$($K -n "$NS" get enterpriseagentgatewaypolicy github-per-agent -o jsonpath='{.metadata.name}' 2>/dev/null)"
# The per-agent policy is part of the platform, not a beat. Missing it means every agent
# in the namespace can use the GitHub credential, and step 6 has nothing to show.
[ -z "$pol" ] && { fail "identity policy" "MISSING: every agent can use the credential"
                   note "fix: ./agents/prtriage/scripts/reset.sh"; } \
              || pass "identity policy" "in place, so each agent gets only its own tools"

# --------------------------------------------------- 7b. egress really is closed
# Tested, not assumed. This lab spent an afternoon believing a sentence about the agent
# having no route to the internet, which was written and never checked, and was wrong.
# So: make the agent try, and fail the preflight if it succeeds.
np="$($K -n "$NS" get networkpolicy agents-egress-through-the-gateway -o jsonpath='{.metadata.name}' 2>/dev/null)"
if [ -z "$np" ]; then
  fail "egress policy" "absent: the agent can reach anything it likes"
else
  out="$($K -n "$NS" exec deploy/prtriagejava -- sh -c \
        'wget -q -O- --timeout=10 https://api.github.com/repos/kagent-dev/kagent 2>&1' 2>/dev/null || true)"
  case "$out" in
    *full_name*) fail "egress policy" "present, but the agent still reached api.github.com" ;;
    *)           pass "egress policy" "the agent cannot reach GitHub except through the gateway" ;;
  esac
fi

# and the model route the policy depends on
mw="$($K -n "$NS" get gateway model-waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
[ "$mw" = "True" ] && pass "model route" "model-waypoint Programmed, agent talks to Anthropic through it" \
                   || fail "model route" "model-waypoint not Programmed: the agent has no way to reach the model"

# ---------------------------------------------------------------- 8. trace visibility
CHPOD="$($K -n solo-cost get pods -l clickhouse.altinity.com/chi -o name 2>/dev/null | head -1)"
CHPOD="${CHPOD:-pod/management-clickhouse-shard0-0}"
spans="$($K -n solo-cost exec "${CHPOD#pod/}" -c clickhouse -- clickhouse-client -q \
  "SELECT count() FROM platformdb.kagent_chat_spans WHERE ServiceName IN ('prtriagejava','releasejava')" 2>/dev/null | tr -d ' ')"
[ "${spans:-0}" -gt 0 ] && pass "trace visibility" "$spans spans from the agents in ClickHouse" \
                        || fail "trace visibility" "no agent spans: the kagent UI Tracing tab will be empty"

echo
if [ "$FAIL" = "0" ]; then
  echo "  ready to present."
else
  echo "  NOT ready. Fix the ✗ lines above."
fi
echo
exit "$FAIL"

#!/usr/bin/env bash
# audit-claims.sh — execute every claim this part makes, and fail on any that does not hold.
#
# WHY THIS EXISTS
# Three claims in this lab were written and never run. One of them said the gateway was
# the agent's only route out while a wget from inside the pod fetched GitHub. In a demo
# about containment that is not a typo, it is the whole thesis undefended. So every
# sentence that asserts something is blocked, held, hidden or impossible now has a check
# here, and the check does the thing rather than reading a manifest that says it is done.
#
#   ./scripts/audit-claims.sh          structural and containment claims (~2 min)
#   FULL=1 ./scripts/audit-claims.sh   also runs the agent end to end in both modes
#
# It drives cluster state (toolMode, the identity policy) and puts it back at the end.
# No pipefail. Every check here reads a specific condition, and pipefail turns a
# `long-running-command | grep -q` into a FALSE FAILURE: grep exits at the first match,
# the producer takes SIGPIPE, and the pipeline reports non-zero *because* it matched.
# That is how C21 reported "not observed" while the line it wanted was in the log 62
# times.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="$HERE/../bin:$PATH"
K="kubectl --context ${CTX:-kind-mesh1}"
NS=kagent
REPO="${DEMO_REPO:-tjorourke/kagent}"
PASS=0; FAIL=0
ok()   { printf "  \033[32m✓\033[0m %-4s %-58s %s\n" "$1" "$2" "${3:-}"; PASS=$((PASS+1)); }
no()   { printf "  \033[31m✗\033[0m %-4s %-58s %s\n" "$1" "$2" "${3:-}"; FAIL=$((FAIL+1)); }
head_() { printf "\n  \033[1m%s\033[0m\n" "$1"; }
mode() { for n in agentgateway-system kagent; do $K -n $n patch enterpriseagentgatewaybackend github-mcp \
           --type merge -p "{\"spec\":{\"entMcp\":{\"toolMode\":\"$1\"}}}" >/dev/null; done
         "$HERE/wait-for-mode.sh" "$1" >/dev/null 2>&1; }
# The in-pod probe, carrying that workload's real identity. It asks the SANDBOX which
# GitHub functions exist, not tools/list: every caller is offered the same get_tool and
# run_code, and the generated catalogue behind them is the thing policy changes.
pod_functions() {
  cat > /tmp/a-probe.json <<'JSON'
{"name": "run_code",
 "arguments": {"code": "Object.keys(globalThis).filter(k => typeof globalThis[k] === 'function').sort()"}}
JSON
  "$HERE/mcp-from-pod.sh" "$1" tools/call /tmp/a-probe.json 2>/dev/null \
    | grep -o '"success":\[[^]]*\]' | grep -o '"[a-z_]*"' | tr -d '"' | grep -v '^success$' | tr '\n' ' '; }

echo; echo "  Claim audit · $REPO"

# ─────────────────────────────────────────────── the tool surface and its cost
head_ "1 · what one MCP server costs"
mode Standard
mcp tools/list > /tmp/a-tools.json 2>/dev/null
n=$(jq '.result.tools | length' /tmp/a-tools.json 2>/dev/null)
[ "${n:-0}" = "93" ] && ok C01 "the gateway offers 93 tools" "$n" || no C01 "the gateway offers 93 tools" "got ${n:-none}"
w=$(jq -r '.result.tools[].name' /tmp/a-tools.json 2>/dev/null | grep -cE \
  '_write$|^(actions_run_trigger|add|create|delete|dismiss|fork|manage|mark|merge|push|request|star|unstar|update)')
[ "${w:-0}" = "31" ] && ok C02 "31 of them can write" "$w" || no C02 "31 of them can write" "got ${w:-none}"
tk=$(jq '{model:"claude-sonnet-4-5", messages:[{role:"user",content:"hi"}],
      tools:[.result.tools[] | {name, description, input_schema: .inputSchema}]}' /tmp/a-tools.json 2>/dev/null |
   curl -s https://api.anthropic.com/v1/messages/count_tokens -d @- \
     -H "x-api-key: ${ANTHROPIC_API_KEY:-}" -H 'anthropic-version: 2023-06-01' \
     -H 'content-type: application/json' | jq -r '.input_tokens // empty')
if [ -n "${tk:-}" ] && [ "$tk" -gt 29000 ] && [ "$tk" -lt 33000 ]; then
  ok C03 "the schemas cost ~30,904 tokens a turn" "$tk"
else no C03 "the schemas cost ~30,904 tokens a turn" "got ${tk:-none}"; fi

# ─────────────────────────────────────────────────────────── the credential
head_ "2 · the gateway holds the credential"
body=$(mcp tools/call "{\"name\":\"list_pull_requests\",\"arguments\":{\"owner\":\"${REPO%/*}\",\"repo\":\"${REPO#*/}\",\"state\":\"open\",\"perPage\":2,\"fields\":[\"number\"]}}" 2>/dev/null)
echo "$body" | grep -q 'number' \
  && ok C04 "a client sending no Authorization still gets GitHub data" "answered" \
  || no C04 "a client sending no Authorization still gets GitHub data" "no data came back"
$K -n agentgateway-system get secret github-mcp-pat >/dev/null 2>&1 \
  && ok C05 "the token is a Secret at the gateway" "Secret/github-mcp-pat" \
  || no C05 "the token is a Secret at the gateway" "not found"
envdump=$($K -n $NS exec deploy/prtriagejava -- env 2>/dev/null)
echo "$envdump" | grep -qE 'github_pat_|ghp_|gho_' \
  && no C06 "the agent pod holds no GitHub credential" "a token-shaped value is in its env" \
  || ok C06 "the agent pod holds no GitHub credential" "no token-shaped value in env"
mcpcfg=$($K -n $NS get deploy prtriagejava -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MCP_SERVERS_CONFIG")].value}' 2>/dev/null)
[ "$(echo "$mcpcfg" | jq 'length' 2>/dev/null)" = "1" ] && echo "$mcpcfg" | grep -q 'github-mcp.kagent.svc' \
  && ok C07 "the only tool endpoint it is given is the gateway" "1 entry, in-cluster" \
  || no C07 "the only tool endpoint it is given is the gateway" "$mcpcfg"

# ─────────────────────────────────────────────────────────── containment
head_ "hosting and containment"
np=$($K -n $NS get networkpolicy agents-egress-through-the-gateway -o jsonpath='{.spec.egress}' 2>/dev/null)
if [ -n "$np" ] && ! echo "$np" | grep -q 'ipBlock'; then
  ok C08 "the egress policy has no rule for the internet" "$(echo "$np" | jq -r '[.[].to[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"] | join(", ")')"
else no C08 "the egress policy has no rule for the internet" "${np:-absent}"; fi
out=$($K -n $NS exec deploy/prtriagejava -- sh -c \
   'wget -q -O- --timeout=10 https://api.github.com/repos/kagent-dev/kagent 2>&1' 2>/dev/null)
echo "$out" | grep -q full_name \
  && no C09 "the agent cannot reach api.github.com directly" "it fetched the repo" \
  || ok C09 "the agent cannot reach api.github.com directly" "blocked"
base=$($K -n $NS get deploy prtriagejava -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ANTHROPIC_BASE_URL")].value}' 2>/dev/null)
echo "$base" | grep -q 'anthropic.kagent.svc' \
  && ok C10 "the model call leaves through a gateway too" "$base" \
  || no C10 "the model call leaves through a gateway too" "${base:-direct to api.anthropic.com}"
mw=$($K -n $NS get gateway model-waypoint -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
[ "$mw" = "True" ] && ok C11 "the model waypoint is programmed" "Programmed=True" \
                   || no C11 "the model waypoint is programmed" "${mw:-missing}"
# Every agent the egress policy names needs the model route, or it dies with "Network is
# unreachable" the first time it thinks. In a demo about refusal that reads as the
# gateway refusing it. Checked per agent, and by reaching the endpoint rather than by
# reading the variable: Anthropic answering 401 to an unauthenticated call proves the
# whole path, and costs nothing.
miss=""; unreach=""
for a in $($K -n $NS get networkpolicy agents-egress-through-the-gateway \
           -o jsonpath='{.spec.podSelector.matchExpressions[0].values[*]}' 2>/dev/null); do
  $K -n $NS get deploy/$a >/dev/null 2>&1 || continue
  [ -n "$($K -n $NS get deploy $a -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ANTHROPIC_BASE_URL")].value}' 2>/dev/null)" ] \
    || miss="$miss $a"
  code=$($K -n $NS exec deploy/$a -- sh -c \
     'wget -S -O /dev/null --timeout=15 --post-data="{}" --header="content-type: application/json" \
      http://anthropic.kagent.svc.cluster.local/v1/messages 2>&1 | grep -m1 "HTTP/" ' 2>/dev/null)
  echo "$code" | grep -qE '40[0-9]|200' || unreach="$unreach $a"
done
[ -z "$miss" ] && ok C31a "every agent the policy names has the model route" "$($K -n $NS get networkpolicy agents-egress-through-the-gateway -o jsonpath='{.spec.podSelector.matchExpressions[0].values}')" \
               || no C31a "every agent the policy names has the model route" "missing:$miss"
[ -z "$unreach" ] && ok C31b "and each of them can actually reach it" "Anthropic answered through the waypoint" \
                  || no C31b "and each of them can actually reach it" "unreachable:$unreach"

$K -n $NS get deploy prtriagejava -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -q ':latest' \
  && ok C12 "kagent hosts it as a BYO image" "$($K -n $NS get agent prtriagejava -o jsonpath='{.spec.type}')" \
  || no C12 "kagent hosts it as a BYO image" "no image"

# ────────────────────────────────────────────── the code says what we claim
head_ "3 · the agent's own code"
src="$HERE/../java-agent/src/main/java/io/solo/demo/ReleaseReport.java"
grep -qiE 'github_pat|ghp_|Authorization' "$src" \
  && no C13 "no credential in the agent source" "found one" \
  || ok C13 "no credential in the agent source" "none"
grep -qE 'list_pull_requests|pull_request_read|merge_pull_request' "$src" \
  && no C14 "no tool list in the agent source" "a tool name is hard-coded" \
  || ok C14 "no tool list in the agent source" "none"

# ─────────────────────────────────────────────────────── the mode change
head_ "5 · one field"
before=$($K -n $NS get pod -l app.kubernetes.io/name=prtriagejava \
         -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)
mode CodeSearch
cs=$(mcp tools/list 2>/dev/null | jq -r '.result.tools[].name' | sort | tr '\n' ' ')
[ "$cs" = "get_tool run_code " ] && ok C15 "CodeSearch leaves exactly get_tool and run_code" "$cs" \
                                || no C15 "CodeSearch leaves exactly get_tool and run_code" "$cs"
"$HERE/reload-agent.sh" prtriagejava >/dev/null 2>&1
after=$($K -n $NS get pod -l app.kubernetes.io/name=prtriagejava \
        -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)
[ -n "$before" ] && [ "$before" = "$after" ] && ok C16 "the image is unchanged across the mode change" "${after##*@}" \
                                            || no C16 "the image is unchanged across the mode change" "$before -> $after"
probe=$(mcp tools/call '{"name":"run_code","arguments":{"code":"const p={}; for (const n of [\"Date\",\"fetch\",\"require\",\"process\"]) { try { p[n]=typeof eval(n) } catch(e) { p[n]=\"MISSING\" } } p"}}' 2>/dev/null \
        | jq -r '.result.content[0].text' 2>/dev/null)
echo "$probe" | grep -q '"Date":"MISSING"' && echo "$probe" | grep -q '"fetch":"MISSING"' \
  && ok C17 "the sandbox has no clock and no network of its own" "Date, fetch, require, process all missing" \
  || no C17 "the sandbox has no clock and no network of its own" "$probe"

# ─────────────────────────────────────────────────── identity and policy
head_ "6 · two agents, different permissions"
$K apply -f "$HERE/../yaml/70-identity-policy.yaml" >/dev/null 2>&1; sleep 6
# step 6 deploys the release agent, so the audit has to as well before testing its claims
if ! $K -n $NS get deploy/releasejava >/dev/null 2>&1; then
  arctl apply -f "$HERE/../yaml/80-release-agent.yaml" >/dev/null 2>&1
  for _ in $(seq 1 90); do $K -n $NS get deploy/releasejava >/dev/null 2>&1 && break; sleep 2; done
  $K -n $NS rollout status deploy/releasejava --timeout=240s >/dev/null 2>&1
  RELEASE_WAS_DEPLOYED_BY_AUDIT=1
fi
for a in prtriagejava releasejava changelogjava; do
  $K -n $NS get deploy/$a >/dev/null 2>&1 && "$HERE/reload-agent.sh" $a >/dev/null 2>&1
done
t=$(pod_functions prtriagejava); r=$(pod_functions releasejava); c=$(pod_functions changelogjava)
[ -n "${t// }" ] && [ -z "${c// }" ] \
  && ok C18 "an agent the policy does not name gets no functions" "triage:[$t] changelog:[${c:-none}]" \
  || no C18 "an agent the policy does not name gets no functions" "triage:[$t] changelog:[$c]"
echo "$r" | grep -q merge_pull_request \
  && ok C24 "the release agent DOES get the merge function" "$r" \
  || no C24 "the release agent DOES get the merge function" "${r:-nothing}"
m1=$("$HERE/try-merge.sh" prtriagejava 2>&1 | tail -1)
m2=$("$HERE/try-merge.sh" releasejava  2>&1 | tail -1)
echo "$m1" | grep -q 'not defined' \
  && ok C19 "the triage agent cannot express a merge" "merge_pull_request is not defined" \
  || no C19 "the triage agent cannot express a merge" "$m1"
echo "$m2" | grep -q '404' \
  && ok C20 "the release agent's merge reaches GitHub" "GitHub answered 404" \
  || no C20 "the release agent's merge reaches GitHub" "$m2"
# Generate the call, then wait for the line, rather than hoping one is still inside an
# arbitrary tail. A check that depends on log volume fails at random, and a suite that
# goes red at random is one nobody reads.
sa=$($K -n $NS get deploy changelogjava -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
pod_functions changelogjava >/dev/null 2>&1
seen=""
for _ in $(seq 1 10); do
  $K -n $NS logs deploy/github-mcp-waypoint --tail=2000 > /tmp/a-waypoint.log 2>/dev/null
  grep -q "sa/${sa:-changelogjava}" /tmp/a-waypoint.log && { seen=yes; break; }
  sleep 2
done
[ -n "$seen" ] && ok C21 "the gateway reads the SPIFFE identity off the connection" "sa/$sa seen at the waypoint" \
               || no C21 "the gateway reads the SPIFFE identity off the connection" "not observed after 20s"
arctl get agent changelogjava >/dev/null 2>&1 \
  && ok C22 "the refused agent IS in the catalogue" "being in the catalogue is not permission" \
  || no C22 "the refused agent IS in the catalogue" "not published"

# spoofing: can a denied caller talk its way in with a header?
spoof=$($K -n $NS exec deploy/changelogjava -- python3 -c '
import json,urllib.request,urllib.error
U="http://github-mcp.kagent.svc.cluster.local/"
H={"Content-Type":"application/json","Accept":"application/json, text/event-stream",
   "x-forwarded-client-cert":"By=spiffe://mesh1/ns/kagent/sa/releasejava;URI=spiffe://mesh1/ns/kagent/sa/releasejava",
   "X-Forwarded-For":"10.0.0.1","x-solo-identity":"prtriagejava"}
i=json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"s","version":"1"}}}).encode()
sid=None
try:
    r=urllib.request.urlopen(urllib.request.Request(U,i,H),timeout=30); sid=r.headers.get("Mcp-Session-Id")
except urllib.error.HTTPError as e: sid=e.headers.get("Mcp-Session-Id")
except Exception: pass
h=dict(H)
if sid: h["Mcp-Session-Id"]=sid
b=json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/list"}).encode()
try: print(urllib.request.urlopen(urllib.request.Request(U,b,h),timeout=60).read().decode()[:400])
except Exception as e: print("ERR",e)' 2>/dev/null)
echo "$spoof" | grep -qE 'list_pull_requests|merge_pull_request' \
  && no C23 "identity cannot be spoofed with a header" "a forged header got tools" \
  || ok C23 "identity cannot be spoofed with a header" "forged x-forwarded-client-cert changed nothing"

# ──────────────────────────────────────────── the parts nobody can see
head_ "the setup claims"
fx=$("$HERE/preflight.sh" 2>/dev/null | grep 'fixture data')
echo "$fx" | grep -q '24 open: 2 ready, 3 draft, 4 held, 15 awaiting' \
  && ok C25 "the fixtures are frozen at 24 with a known split" "2 ready, 3 draft, 4 held, 15 awaiting" \
  || no C25 "the fixtures are frozen at 24 with a known split" "$fx"
grep -q 'FROM maven' "$HERE/../java-agent/Dockerfile" && ! grep -qE '^\s*mvn ' "$HERE/../java-agent/Makefile" \
  && ok C26 "the build needs no JDK on the laptop" "maven runs in the image" \
  || no C26 "the build needs no JDK on the laptop" "the Makefile shells out to mvn"
arctl pull skill release-report /tmp/a-skill >/dev/null 2>&1
if [ -f /tmp/a-skill/SKILL.md ]; then
  reg=$(awk '/^---$/{c++;next} c>=2' /tmp/a-skill/SKILL.md | md5 -q 2>/dev/null || awk '/^---$/{c++;next} c>=2' /tmp/a-skill/SKILL.md | md5sum | cut -d" " -f1)
  pod=$($K -n $NS exec deploy/prtriagejava -- md5sum /app/skill.md 2>/dev/null | cut -d' ' -f1)
  [ -z "$pod" ] && pod=$($K -n $NS exec deploy/prtriagejava -- sh -c 'command -v md5sum >/dev/null && md5sum /app/skill.md' 2>/dev/null | cut -d' ' -f1)
  if [ -n "$pod" ] && [ "$reg" = "$pod" ]; then
    ok C27 "the running agent carries the registry's skill" "same digest"
  elif [ -z "$pod" ]; then
    no C27 "the running agent carries the registry's skill" "could not hash it in the pod"
  else
    no C27 "the running agent carries the registry's skill" "registry $reg, pod $pod"
  fi
else no C27 "the running agent carries the registry's skill" "arctl pull skill failed"; fi
# the sandbox's 20-call ceiling, which is what sizes any fan-out job
mode CodeSearch
cap=$(mcp tools/call '{"name":"run_code","arguments":{"code":"let n=0; for (let i=0;i<21;i++) { await get_me({}); n++ } n"}}' 2>/dev/null \
      | jq -r '.result.content[0].text' 2>/dev/null)
# match the gateway's actual words, not any error that happens to mention a number
echo "$cap" | grep -qi 'exceeded the maximum of 20 tool calls' \
  && ok C28 "a program is capped at 20 upstream calls" "the gateway says so at 21" \
  || no C28 "a program is capped at 20 upstream calls" "21 calls were allowed: $(echo "$cap" | head -c 90)"

if [ -n "${FULL:-}" ]; then
  head_ "end to end, both modes"
  mode CodeSearch; "$HERE/reload-agent.sh" prtriagejava >/dev/null 2>&1
  AGENT_PREFIX=prtriagejava "$HERE/../../../demo-scripts/agentregistry/scripts/ask.sh" \
     "Give me the release report for $REPO, all open pull requests." > /tmp/a-cs.txt 2>&1
  if "$HERE/check-report.sh" /tmp/a-cs.txt >/dev/null 2>&1; then
    ok C29 "CodeSearch matches the fixture" "$("$HERE/trace-cost.sh" /tmp/a-cs.txt | head -1 | tr -s ' ')"
  else no C29 "CodeSearch matches the fixture" "$("$HERE/check-report.sh" /tmp/a-cs.txt 2>&1 | grep -c '^      -') mismatches"; fi
  mode Standard; "$HERE/reload-agent.sh" prtriagejava >/dev/null 2>&1
  AGENT_PREFIX=prtriagejava "$HERE/../../../demo-scripts/agentregistry/scripts/ask.sh" \
     "Give me the release report for $REPO, all open pull requests." > /tmp/a-std.txt 2>&1
  if "$HERE/check-report.sh" /tmp/a-std.txt >/dev/null 2>&1; then
    ok C30 "Standard matches the fixture" "$("$HERE/trace-cost.sh" /tmp/a-std.txt | head -1 | tr -s ' ')"
  else no C30 "Standard matches the fixture" "stochastic at this size: see the guide"; fi
fi

# ───────────────────────────────────────────────────────────── restore
$K -n $NS delete enterpriseagentgatewaypolicy github-per-agent --ignore-not-found >/dev/null 2>&1
if [ -n "${RELEASE_WAS_DEPLOYED_BY_AUDIT:-}" ]; then
  arctl delete deployment releasejava >/dev/null 2>&1; arctl delete agent releasejava >/dev/null 2>&1
  $K -n $NS delete deploy releasejava --ignore-not-found >/dev/null 2>&1
fi
mode Standard
"$HERE/reload-agent.sh" prtriagejava >/dev/null 2>&1
echo
printf "  %d passed, %d failed\n\n" "$PASS" "$FAIL"
exit $(( FAIL > 0 ))

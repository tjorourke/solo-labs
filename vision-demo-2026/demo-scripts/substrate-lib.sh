#!/usr/bin/env bash
# substrate-lib.sh — the helpers behind demo-5-substrate.ipynb. Source it (the notebook's
# Connect cell and `source demo-scripts/env.sh 5` both do), then the cells read as
# kubectl + YAML + one named command each:
#
#   show <file>                 print a manifest without comments or blank lines
#   wait-ready <kind> <name> <file>   wait for Ready, re-applying to reset the controller backoff
#   time-ready <kind> <name> <file>   apply + wait, print how long it took
#   ask <agent> "<text>"        one A2A message/send to a sandboxed agent, in a fresh session
#   ask-in <session> <agent> "<text>"   the same, in a session you opened with `session`
#   session <agent> [name]      open a kagent session, print its id (the A2A contextId)
#   ask-pod <agent> "<text>"    the same for an ordinary pod-backed Agent
#   actors [filter]             kagent's substrate inventory: every actor, state and version
#   workers                     the workers, by pool
#   templates <agent>           the ActorTemplates behind a SandboxAgent
#   watch-turn <agent> "<text>" fire a turn and sample the actor's state while it runs
#   catch-runsc <agent> "<text>"  fire a turn and catch the gVisor processes on the node
#   on-node [agent]             the actor directories on the worker node, cross-checked
#   fire <n> <agent>            n turns at the same moment, each timed
#   delete-session <session>    delete a session and show its actor go
#   registered-workers [pool]   how many workers the api-server has in its store
#
# Every helper talks to the kagent controller through one port-forward on :18083,
# started on first use and left up until `pf-down` (the Teardown cell calls it).
# Never changes your kubectl context: everything addresses $CTX explicitly.

: "${SUBSTRATE_CTX:=kind-substrate}"
export CTX="${CTX:-$SUBSTRATE_CTX}" KAGENT_NS="${KAGENT_NS:-kagent}"
export SUBSTRATE_API="${SUBSTRATE_API:-http://localhost:18083}"
export CYN=$'\e[36m' GRN=$'\e[32m' BLD=$'\e[1m' RST=$'\e[0m'
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_LIB_DIR/.." || return 1        # the suite root, so ./demo-scripts/... works from anywhere
export SUBSTRATE_YAML="$_LIB_DIR/yaml-substrate"
_PF_PID_FILE="${TMPDIR:-/tmp}/substrate-demo-pf.pid"

# ── plumbing ─────────────────────────────────────────────────────────────────────
pf-up() {
  curl -s -o /dev/null -m 2 "$SUBSTRATE_API/api/sessions" 2>/dev/null && return 0
  [ -x "$_LIB_DIR/free-ports.sh" ] && "$_LIB_DIR/free-ports.sh" 18083 >/dev/null 2>&1
  nohup kubectl --context "$CTX" -n "$KAGENT_NS" port-forward svc/kagent-controller 18083:8083 >/dev/null 2>&1 </dev/null &
  echo $! > "$_PF_PID_FILE"
  for i in $(seq 1 20); do curl -s -o /dev/null -m 2 "$SUBSTRATE_API/api/sessions" 2>/dev/null && return 0; sleep 1; done
  echo "could not reach the kagent controller on $SUBSTRATE_API" >&2; return 1
}
pf-down() {
  [ -f "$_PF_PID_FILE" ] && kill "$(cat "$_PF_PID_FILE")" 2>/dev/null; rm -f "$_PF_PID_FILE"
  pkill -f 'port-forward svc/kagent-controller 18083' 2>/dev/null || true
}
_status() { pf-up || return 1; curl -s --max-time 10 "$SUBSTRATE_API/api/substrate/status"; }
_now() { python3 -c 'import time;print(time.time())'; }
_since() { python3 -c "import time;print(f'{time.time()-$1:.1f}')"; }

# ── manifests and readiness ──────────────────────────────────────────────────────
show() { grep -vE '^\s*#|^\s*$' "$1"; }

wait-ready() { # wait-ready <kind> <name> [file]  — re-applies the file on each retry, which resets
  local kind=$1 name=$2 file=${3:-} attempt   # the ate-controller's exponential backoff
  for attempt in 1 2 3 4 5 6; do
    if kubectl --context "$CTX" -n "$KAGENT_NS" wait "$kind/$name" --for=condition=Ready --timeout=60s >/dev/null 2>&1; then
      echo "✓ $name Ready (attempt $attempt)"; return 0
    fi
    local msg; msg=$(kubectl --context "$CTX" -n "$KAGENT_NS" get "$kind" "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    echo "  attempt $attempt: not Ready yet (${msg:-no status}) - retrying"
    if [ -n "$file" ]; then
      kubectl --context "$CTX" -n "$KAGENT_NS" delete "$kind" "$name" --ignore-not-found >/dev/null 2>&1
      kubectl --context "$CTX" apply -f "$file" >/dev/null
    fi
  done
  echo "✗ $name did not become Ready"; return 1
}

time-ready() { # time-ready <kind> <name> <file>  — apply, wait for Ready, print the time it took
  local t0; t0=$(_now)
  kubectl --context "$CTX" apply -f "$3" >/dev/null && wait-ready "$1" "$2" "$3" >/dev/null
  python3 -c "import time;print(f'   $2 Ready in {(time.time()-$t0)*1000:.0f} ms')"
}

# ── talking to agents ────────────────────────────────────────────────────────────
session() { # session <agent> [name] -> prints the session id, which is the A2A contextId
  pf-up || return 1
  curl -s --max-time 15 -X POST "$SUBSTRATE_API/api/sessions" -H 'content-type: application/json' \
    -d "{\"agent_ref\":\"$KAGENT_NS/$1\",\"name\":\"${2:-demo}\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("data",{}).get("id",""))'
}

_a2a() { # _a2a <path> <session> "<text>"  — one message/send, printed as the reply plus any tool calls
  local req; req=$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','parts':[{'kind':'text','text':sys.argv[1]}],'messageId':'m1','contextId':sys.argv[2]}}}))" "$3" "$2")
  printf '%s> %s%s\n' "$CYN$BLD" "$3" "$RST"
  curl -s --max-time 180 -X POST "$SUBSTRATE_API$1" -H 'content-type: application/json' -d "$req" \
  | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("  (no answer: empty response)"); sys.exit(0)
r=d.get("result",{}); arts=r.get("artifacts",[])
if arts: print("  "+arts[0]["parts"][0].get("text","").strip().replace("\n","\n  "))
else:    print("  (no answer: "+str(d.get("error",{}).get("message","?"))[:220]+")")
for m in r.get("history",[]):
    for p in m.get("parts",[]):
        dd=p.get("data") or {}
        if p.get("kind")=="data" and "name" in dd:
            print("     tool "+dd["name"]+("  args="+json.dumps(dd.get("args"))[:90] if "args" in dd else "  -> result, "+str(len(json.dumps(dd.get("response"))))+" bytes"))'
}
ask()     { local sid; sid=$(session "$1" ask) || return 1; [ -n "$sid" ] || { echo "  cannot open a session for $1 (is it Ready?)"; return 1; }; _a2a "/api/a2a-sandboxes/$KAGENT_NS/$1/" "$sid" "$2"; }
_settle() { # _settle <session>  — a turn sent while the previous checkpoint is still in flight cannot be routed; wait for Suspended
  local i; for i in $(seq 1 40); do case "$(_actor_state "$1")" in Suspended*|"no actor yet") return 0;; esac; sleep 1; done; return 0
}
ask-in()  { pf-up || return 1; _settle "$1"; _a2a "/api/a2a-sandboxes/$KAGENT_NS/$2/" "$1" "$3"; }
ask-pod() { local sid; sid=$(session "$1" ask) || return 1; _a2a "/api/a2a/$KAGENT_NS/$1/" "$sid" "$2"; }

# ── the inventory ────────────────────────────────────────────────────────────────
actors() { # actors [substring]  — every actor kagent knows about, or those matching the filter
  _status | python3 -c '
import sys,json
f=sys.argv[1] if len(sys.argv)>1 else ""
d=json.load(sys.stdin)["data"]
rows=[a for a in d["actors"] if f in a["actorId"] or f in a["actorTemplateName"]]
print("  %-10s %-4s %-52s %s" % ("STATE","VER","ACTOR","TEMPLATE"))
for a in sorted(rows, key=lambda a:(a["atespace"]!="ate-golden", a["actorId"])):
    kind = "golden of "+a["actorTemplateName"] if a["atespace"]=="ate-golden" else "session actor of "+a["actorTemplateName"]
    print("  %-10s v%-3s %-52s %s" % (a["status"], a["version"], a["actorId"][:52], kind))
print("  %d actors in total, %d workers" % (len(d["actors"]), len(d["workers"])))' "${1:-}"
}
workers() {
  _status | python3 -c '
import sys,json; d=json.load(sys.stdin)["data"]
print("  %-16s %-46s %s" % ("POOL","WORKER POD","IP"))
for w in d["workers"]: print("  %-16s %-46s %s" % (w["workerPool"], w["workerPod"], w["ip"]))'
}
registered-workers() { _status | python3 -c "import sys,json;d=json.load(sys.stdin)['data'];print(len([w for w in d['workers'] if w['workerPool']=='${1:-kagent-default}']))"; }
templates() { # templates <agent>
  kubectl --context "$CTX" -n "$KAGENT_NS" get actortemplate -l "kagent.dev/sandbox-agent=$1" \
    -o custom-columns='ACTORTEMPLATE:.metadata.name,GENERATION:.metadata.annotations.kagent\.dev/desired-generation,PHASE:.status.phase,POOL:.spec.workerSelector.matchLabels.kagent\.dev/worker-pool,GOLDEN:.status.goldenActorID'
}
_actor_state() { # _actor_state <session>
  _status | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
a=[x for x in d['actors'] if '$1' in x['actorId']]
print((a[0]['status']+' v'+str(a[0]['version'])) if a else 'no actor yet')"
}

# ── the beats ────────────────────────────────────────────────────────────────────
watch-turn() { # watch-turn <agent> "<text>"  — the actor's state, sampled while one turn runs
  local sid t0 last="" s turn
  sid=$(session "$1" watch) || return 1
  printf '%s== before: %s ==%s\n' "$CYN$BLD" "$(_actor_state "$sid")" "$RST"
  _a2a "/api/a2a-sandboxes/$KAGENT_NS/$1/" "$sid" "$2" > "${TMPDIR:-/tmp}/substrate-turn.txt" 2>&1 &
  turn=$!; t0=$(_now)
  while kill -0 $turn 2>/dev/null; do
    s=$(_actor_state "$sid"); [ "$s" != "$last" ] && { echo "  t+$(_since $t0)s  $s"; last=$s; }; sleep 0.5
  done
  wait $turn 2>/dev/null
  for i in $(seq 1 40); do
    s=$(_actor_state "$sid"); [ "$s" != "$last" ] && { echo "  t+$(_since $t0)s  $s"; last=$s; }
    case "$s" in Suspended*) break;; esac; sleep 0.5
  done
  echo; cat "${TMPDIR:-/tmp}/substrate-turn.txt"
}

catch-runsc() { # catch-runsc <agent> "<text>"  — fire a turn, watch the node's process table during it
  local node sid turn caught=""
  node=$(kubectl --context "$CTX" -n "$KAGENT_NS" get pod -l ate.dev/worker-pool=kagent-default -o jsonpath='{.items[0].spec.nodeName}')
  echo "worker node (kind runs it as a container): $node"
  sid=$(session "$1" gvisor-probe) || return 1
  _a2a "/api/a2a-sandboxes/$KAGENT_NS/$1/" "$sid" "$2" > "${TMPDIR:-/tmp}/substrate-runsc-turn.txt" 2>&1 &
  turn=$!
  for i in $(seq 1 80); do
    caught=$(docker exec "$node" sh -c 'ps -ef | grep "[r]unsc"' 2>/dev/null); [ -n "$caught" ] && break; sleep 0.25
  done
  wait $turn 2>/dev/null
  if [ -n "$caught" ]; then
    printf '%s== gVisor processes serving that turn ==%s\n' "$GRN$BLD" "$RST"
    printf '%s\n' "$caught" | grep -oE 'runsc-(sandbox|gofer)' | sort | uniq -c | sed 's/^/  /'
    printf '%s== the actor they were booted for ==%s\n' "$CYN$BLD" "$RST"
    printf '%s\n' "$caught" | grep -oE '/var/lib/ateom-gvisor/actors/[^/]+' | sort -u | sed 's/^/  /'
    echo
    echo "  runsc-sandbox  the gVisor guest kernel, booted for this actor"
    echo "  runsc-gofer    gVisor's file proxy: the actor never touches the host filesystem directly"
  else
    echo "no runsc seen: the turn finished inside the poll window, run the cell again"
  fi
  echo; cat "${TMPDIR:-/tmp}/substrate-runsc-turn.txt"
}

on-node() { # on-node [agent]  — actor directories on the worker node, cross-checked with kagent's inventory
  local node filter=${1:-} live known running stale=0 stale_s=0 d state
  node=$(kubectl --context "$CTX" -n "$KAGENT_NS" get pod -l ate.dev/worker-pool=kagent-default -o jsonpath='{.items[0].spec.nodeName}')
  live=$(kubectl --context "$CTX" -n "$KAGENT_NS" get actortemplate -o jsonpath='{range .items[*]}{.status.goldenActorID}{"\n"}{end}' 2>/dev/null)
  known=$(_status | python3 -c 'import sys,json; print("\n".join(a["actorId"] for a in json.load(sys.stdin)["data"]["actors"]))')
  running=$(docker exec "$node" sh -c 'ps -ef | grep "[r]unsc-sandbox"' 2>/dev/null | grep -oE 'actors/[^/]+' | sort -u)
  printf '%s== actor directories on %s ==%s\n' "$CYN$BLD" "$node" "$RST"
  while read -r d; do
    [ -n "$d" ] || continue
    if printf '%s\n' "$running" | grep -q "actors/$d"; then state="runsc process alive"; else state="no process, snapshot only"; fi
    case "$d" in
      ate-golden:*)
        if printf '%s\n' "$live" | grep -qx "${d#ate-golden:}"; then printf '  %-62s golden, live agent   %s\n' "$d" "$state"
        else stale=$((stale+1)); fi ;;
      kagent:asr-*)
        if printf '%s\n' "$known" | grep -qx "${d#kagent:}"; then printf '  %-62s one session          %s\n' "${d:0:62}" "$state"
        else stale_s=$((stale_s+1)); fi ;;
    esac
  done <<< "$(docker exec "$node" sh -c 'ls /var/lib/ateom-gvisor/actors/ 2>/dev/null' | grep -E "${filter}|ate-golden")"
  [ $((stale+stale_s)) -gt 0 ] && echo "  (+ $stale golden and $stale_s session snapshots left by agents since deleted)"
  return 0
}

fire() { # fire <n> <agent>  — n turns at the same moment; each line is one turn's wall time and outcome
  local n=$1 agent=$2 i; local pids=()
  pf-up || return 1; rm -f "${TMPDIR:-/tmp}"/substrate-fire-*.txt
  for i in $(seq 1 "$n"); do
    ( local sid t0 req out
      sid=$(session "$agent" "fire-$i")
      req=$(python3 -c "import json,sys;print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','parts':[{'kind':'text','text':'Reply with the single word ready.'}],'messageId':'m1','contextId':sys.argv[1]}}}))" "$sid")
      t0=$(_now)
      out=$(curl -s --max-time 180 -X POST "$SUBSTRATE_API/api/a2a-sandboxes/$KAGENT_NS/$agent/" -H 'content-type: application/json' -d "$req")
      python3 -c "
import sys,json,time
t=time.time()-$t0
try: d=json.loads(sys.argv[1])
except Exception: d={}
ok='artifacts' in d.get('result',{}); msg=str(d.get('error',{}).get('message',''))
print(f'  turn $i: {t:5.1f}s  ' + ('answered' if ok else 'refused: '+msg[msg.rfind('substrate'):][:96]))" "$out" > "${TMPDIR:-/tmp}/substrate-fire-$i.txt"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  cat "${TMPDIR:-/tmp}"/substrate-fire-*.txt | sort
}

delete-session() { # delete-session <session>  — wait for the actor to settle, delete the session, show the actor go
  local sid=$1 i code
  pf-up || return 1
  for i in $(seq 1 30); do case "$(_actor_state "$sid")" in Suspended*|"no actor yet") break;; esac; sleep 1; done
  echo "  actor before: $(_actor_state "$sid")"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$SUBSTRATE_API/api/sessions/$sid" -H 'X-User-Id: admin@kagent.dev')
  echo "  DELETE /api/sessions/${sid:0:8}...  -> HTTP $code"
  for i in $(seq 1 20); do [ "$(_actor_state "$sid")" = "no actor yet" ] && break; sleep 1; done
  echo "  actor after:  $(_actor_state "$sid" | sed 's/no actor yet/none, gone/')   (${i}s later)"
}

scale-pool() { # scale-pool <replicas> [pool]  — kubectl scale, then wait until the api-server has the workers in its store
  local n=$1 pool=${2:-kagent-default} i have running before
  before=$(registered-workers "$pool")
  kubectl --context "$CTX" -n "$KAGENT_NS" scale "workerpool/$pool" --replicas="$n"
  for i in $(seq 1 90); do   # poll the Running pod count: `kubectl wait` trips over pods that are terminating
    running=$(kubectl --context "$CTX" -n "$KAGENT_NS" get pods -l "ate.dev/worker-pool=$pool" --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -vc Terminating)
    [ "${running:-0}" -eq "$n" ] && break; sleep 2
  done
  if [ "$n" -gt "${before:-0}" ]; then
    for i in $(seq 1 60); do have=$(registered-workers "$pool"); [ "${have:-0}" -ge "$n" ] && break; sleep 3; done
    echo "  $pool: $have workers registered with the api-server"
    sleep 45   # a worker shows up in the store a little before its sandbox runtime accepts actors
  else
    sleep 5; echo "  $pool: back to $n worker(s)"
  fi
  return 0
}
wait-templates() { # wait-templates <agent> <count>  — until that many of the agent's ActorTemplates are Ready
  local i n t0; t0=$(_now)
  for i in $(seq 1 120); do
    n=$(kubectl --context "$CTX" -n "$KAGENT_NS" get actortemplate -l "kagent.dev/sandbox-agent=$1" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Ready)
    [ "${n:-0}" -ge "$2" ] && { echo "  $2 templates Ready after $(_since $t0)s"; return 0; }; sleep 1
  done
  echo "  only $n template(s) Ready"; return 1
}
wait-pod-agent() { # wait-pod-agent <agent>  — Ready is the agent card; wait for the pod's A2A server to accept connections too
  kubectl --context "$CTX" -n "$KAGENT_NS" wait "agent/$1" --for=condition=Ready --timeout=180s >/dev/null && echo "✓ $1 Ready (a Deployment)"
  local i; for i in $(seq 1 30); do [ -n "$(kubectl --context "$CTX" -n "$KAGENT_NS" get endpoints "$1" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ] && break; sleep 2; done; sleep 5
  kubectl --context "$CTX" -n "$KAGENT_NS" get deploy "$1" --no-headers 2>/dev/null | sed 's/^/  /'
}

echo "demo-5 · context: $CTX · namespace: $KAGENT_NS · helpers: show, wait-ready, ask, actors, workers, templates, watch-turn, catch-runsc, on-node, fire, scale-pool, delete-session"
kubectl --context "$CTX" get crd workerpools.ate.dev >/dev/null 2>&1 \
  && echo "  Agent Substrate: installed ($(kubectl --context "$CTX" -n "$KAGENT_NS" get workerpool kagent-default -o jsonpath='{.status.replicas}' 2>/dev/null) workers in kagent-default)" \
  || echo "  Agent Substrate: not installed here; run the Enable cell at the bottom"

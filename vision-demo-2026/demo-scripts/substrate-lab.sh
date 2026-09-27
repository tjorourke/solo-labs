# substrate-lab.sh — the Agent Substrate lab's helpers, on top of substrate-lib.sh.
# The console runs every step in a fresh shell, so the one conversation the lab
# follows is kept in a file between steps.
#
#   wait-pool <pool> <n>       until the pool has n Running workers AND the api-server has them
#   show-template <agent>      the ActorTemplate kagent rendered, trimmed to what matters
#   wait-harness <name>        until an AgentHarness is Ready, printing each condition change
#   pool-templates <pool>      every ActorTemplate that runs on a pool, and who owns it
#   turn-loop <n> <agent>      n turns in one conversation, one after another: each resumes the
#                              actor, catches gVisor serving it, and lets it suspend again
#   grow-pool <n>              scale lab-pool to n workers and wait until Substrate can use them
#   load-run <clients> <secs> <agent>   sustained load: each client is its own conversation
#                              (its own actor) sending turns back to back; a refused turn
#                              waits a moment and retries, so every worker stays busy
#   lab-session <agent>        open the lab's conversation with an agent, remember it
#   lab-ask "<text>"           one turn in that conversation, with the actor's state before,
#                              during and after (Suspended -> Resuming -> Running -> Suspended)
#   lab-actor                  that conversation's actor right now: state, snapshot version
#   lab-snapshots [agent]      the actor directories on the worker node, and whether a
#                              gVisor process is alive for any of them
. "$(dirname "${BASH_SOURCE[0]}")/substrate-lib.sh" >/dev/null 2>&1

_LAB_SID="${TMPDIR:-/tmp}/substrate-lab.session"

lab-session() { # lab-session <agent>
  local sid
  sid=$(session "$1" lab) || return 1
  [ -n "$sid" ] || { echo "  cannot open a session for $1 (is it Ready?)"; return 1; }
  printf '%s %s\n' "$sid" "$1" > "$_LAB_SID"
  echo "  session ${sid} opened on $1"
  echo "  its actor: asr-kagent-$1-${sid}"
}

_lab() { [ -s "$_LAB_SID" ] || { echo "  no lab session yet: run the step that opens one"; return 1; }; read -r LAB_SID LAB_AGENT < "$_LAB_SID"; }

lab-actor() {
  _lab || return 1
  echo "  actor asr-kagent-$LAB_AGENT-${LAB_SID:0:8}...: $(_actor_state "$LAB_SID")"
}

lab-ask() { # lab-ask "<text>"  — like watch-turn, but in the lab's own conversation
  local t0 last="" s turn out="${TMPDIR:-/tmp}/substrate-lab-turn.txt"
  _lab || return 1
  pf-up || return 1
  _settle "$LAB_SID"
  printf '%s== before: %s ==%s\n' "$CYN$BLD" "$(_actor_state "$LAB_SID")" "$RST"
  _a2a "/api/a2a-sandboxes/$KAGENT_NS/$LAB_AGENT/" "$LAB_SID" "$1" > "$out" 2>&1 &
  turn=$!; t0=$(_now)
  while kill -0 $turn 2>/dev/null; do
    s=$(_actor_state "$LAB_SID"); [ "$s" != "$last" ] && { echo "  t+$(_since $t0)s  $s"; last=$s; }; sleep 0.4
  done
  wait $turn 2>/dev/null
  for _ in $(seq 1 40); do
    s=$(_actor_state "$LAB_SID"); [ "$s" != "$last" ] && { echo "  t+$(_since $t0)s  $s"; last=$s; }
    case "$s" in Suspended*) break;; esac; sleep 0.4
  done
  echo; cat "$out"
}

lab-snapshots() { # lab-snapshots [agent]
  local node agent="${1:-}" running
  _lab 2>/dev/null && agent="${agent:-$LAB_AGENT}"
  node=$(kubectl --context "$CTX" -n "$KAGENT_NS" get pod -l ate.dev/worker-pool=lab-pool -o jsonpath='{.items[0].spec.nodeName}')
  running=$(docker exec "$node" sh -c 'ps -ef | grep "[r]unsc-sandbox"' 2>/dev/null | grep -oE 'actors/[^/ ]+' | sort -u || true)
  printf '%s== %s actors on %s ==%s\n' "$CYN$BLD" "$agent" "$node" "$RST"
  docker exec "$node" sh -c 'ls /var/lib/ateom-gvisor/actors/' 2>/dev/null | grep -- "$agent" | while read -r d; do
    if printf '%s\n' "$running" | grep -q "actors/$d"; then state="gVisor process running"; else state="snapshot on disk, no process"; fi
    printf '  %-66s %s\n' "${d:0:66}" "$state"
  done || true
  printf '  gVisor sandboxes alive on the node right now: %s\n' "$(printf '%s\n' "$running" | grep -c . )"
}

wait-pool() { # wait-pool <pool> <n>
  local pool=$1 n=$2 i t0; t0=$(_now)
  kubectl --context "$CTX" -n "$KAGENT_NS" wait "workerpool/$pool" --for=jsonpath='{.status.replicas}'="$n" --timeout=180s >/dev/null
  # Running pods are not enough: kagent can only place actors once the api-server has the workers
  for i in $(seq 1 100); do [ "$(registered-workers "$pool")" -ge "$n" ] 2>/dev/null && break; sleep 3; done
  echo "  $pool: $n workers Running and registered with the substrate api-server in $(_since "$t0")s"
  kubectl --context "$CTX" -n "$KAGENT_NS" get pods -l "ate.dev/worker-pool=$pool" -o wide --no-headers | awk '{printf "  %-44s %s  node %s\n", $1, $3, $7}'
}

show-template() { # show-template <agent>
  kubectl --context "$CTX" -n "$KAGENT_NS" get actortemplate -l "kagent.dev/sandbox-agent=$1" -o json | python3 -c '
import json,sys
for t in json.load(sys.stdin)["items"]:
    s=t["spec"]; c=s["containers"][0]
    print("  name:          ", t["metadata"]["name"], "  (agent name + a hash of its shape)")
    print("  owner:         ", t["metadata"]["ownerReferences"][0]["kind"], t["metadata"]["ownerReferences"][0]["name"])
    print("  sandbox class: ", s.get("sandboxClass"))
    print("  runs on:       ", "workers labelled", ",".join(f"{k}={v}" for k,v in s.get("workerSelector",{}).get("matchLabels",{}).items()))
    print("  image:         ", c["image"].split("@")[0], "(pinned by digest)")
    print("  agent config:  ", ", ".join(e["name"] for e in c.get("env",[]) if "valueFrom" in e and "secretKeyRef" in e["valueFrom"]), "(from Secrets)")
    print("  readiness:     ", c.get("readyz",{}).get("httpGet",{}).get("path"))
    print("  snapshotted:   ", ", ".join(v["mountPath"] for v in c.get("volumeMounts",[])), "(the data the actor carries between turns)")
    st=t.get("status",{})
    print("  phase:         ", st.get("phase"), "  golden actor", st.get("goldenActorID"))'
}

wait-harness() { # wait-harness <name>
  local i s last="" t0; t0=$(_now)
  for i in $(seq 1 120); do
    s=$(kubectl --context "$CTX" -n "$KAGENT_NS" get agentharness "$1" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)
    [ "$s" != "$last" ] && { echo "  t+$(_since "$t0")s  $s"; last=$s; }
    case "$s" in *"Ready=True"*) break;; esac; sleep 3
  done
  kubectl --context "$CTX" -n "$KAGENT_NS" get agentharness "$1" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}  {.message}{"\n"}{end}'
}

pool-templates() { # pool-templates <pool>
  kubectl --context "$CTX" -n "$KAGENT_NS" get actortemplate -o json | python3 -c '
import json,sys
pool=sys.argv[1]
print("  %-32s %-24s %-7s %s" % ("ACTORTEMPLATE","OWNED BY","PHASE","GOLDEN ACTOR"))
for t in json.load(sys.stdin)["items"]:
    if t["spec"].get("workerSelector",{}).get("matchLabels",{}).get("kagent.dev/worker-pool")!=pool: continue
    o=t["metadata"]["ownerReferences"][0]; st=t.get("status",{})
    print("  %-32s %-24s %-7s %s" % (t["metadata"]["name"], o["kind"]+"/"+o["name"], st.get("phase",""), st.get("goldenActorID","")))' "$1"
}

turn-loop() { # turn-loop <n> <agent>  — watch one actor go round the cycle n times
  local n=$1 agent=$2 i sid node t0 s last seen trail out="${TMPDIR:-/tmp}/substrate-loop-turn.txt"
  pf-up || return 1
  node=$(kubectl --context "$CTX" -n "$KAGENT_NS" get pod -l ate.dev/worker-pool=lab-pool -o jsonpath='{.items[0].spec.nodeName}')
  sid=$(session "$agent" loop) || return 1
  echo "  one conversation, $n turns: actor asr-kagent-$agent-${sid:0:8}...  (watch it on the App tab)"
  for i in $(seq 1 "$n"); do
    _settle "$sid"
    trail="$(_actor_state "$sid")"; last=$trail; seen=""
    _a2a "/api/a2a-sandboxes/$KAGENT_NS/$agent/" "$sid" "In one sentence, tell me something interesting about the number $i." > "$out" 2>&1 &
    local turn=$!; t0=$(_now)
    while kill -0 $turn 2>/dev/null; do
      s=$(_actor_state "$sid"); [ "$s" != "$last" ] && { trail="$trail -> $s"; last=$s; }
      [ -z "$seen" ] && docker exec "$node" sh -c 'ps -ef | grep "[r]unsc-sandbox"' 2>/dev/null | grep -q "$sid" && seen=yes
      sleep 0.3
    done
    wait $turn 2>/dev/null || true
    for _ in $(seq 1 40); do
      s=$(_actor_state "$sid"); [ "$s" != "$last" ] && { trail="$trail -> $s"; last=$s; }
      case "$s" in Suspended*) break;; esac; sleep 0.3
    done
    printf '  turn %s/%s  %5ss  gVisor %-9s %s\n' "$i" "$n" "$(_since "$t0")" "$([ -n "$seen" ] && echo caught || echo 'not seen')" "$trail"
    grep -m1 -E '^  [^>]' "$out" | cut -c1-110 | sed 's/^/             /'
    [ "$i" -lt "$n" ] && sleep "${LOOP_GAP:-3}"   # long enough to see it at rest on the App tab
  done
  echo "  after the last turn: actor $(_actor_state "$sid"), gVisor sandboxes alive on the node: $(docker exec "$node" sh -c 'ps -ef | grep -c "[r]unsc-sandbox"' 2>/dev/null || true)"
  return 0
}

grow-pool() { # grow-pool <n>
  local n=$1 i t0 have=0; t0=$(_now)
  kubectl --context "$CTX" -n "$KAGENT_NS" scale workerpool/lab-pool --replicas="$n"
  for i in $(seq 1 90); do
    [ "$(kubectl --context "$CTX" -n "$KAGENT_NS" get pods -l ate.dev/worker-pool=lab-pool --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -vc Terminating || true)" -ge "$n" ] && break; sleep 2
  done
  for i in $(seq 1 60); do have=$(registered-workers lab-pool); [ "${have:-0}" -ge "$n" ] && break; sleep 2; done
  # a worker is in the api-server's store a few seconds before its sandbox runtime takes actors
  sleep 12
  echo "  lab-pool: $have workers registered and ready in $(_since "$t0")s"
}

load-run() { # load-run <clients> <seconds> <agent>
  local clients=$1 secs=$2 agent=$3 c dir end; local pids=()
  pf-up || return 1
  dir=$(mktemp -d); end=$(( $(date +%s) + secs ))
  echo "  $clients conversations, each its own actor, sending turns for ${secs}s on $(registered-workers lab-pool) workers"
  for c in $(seq 1 "$clients"); do
    ( local sid n=0 req out
      sid=$(session "$agent" "load-$c") || exit 0
      while [ "$(date +%s)" -lt "$end" ]; do
        _settle "$sid"     # the next turn can only be routed once the last one is Suspended
        n=$((n+1))
        req=$(python3 -c "import json,sys;print(json.dumps({'jsonrpc':'2.0','id':'1','method':'message/send','params':{'message':{'role':'user','parts':[{'kind':'text','text':'In one short sentence, tell me something about the number '+sys.argv[2]+'.'}],'messageId':'m'+sys.argv[2],'contextId':sys.argv[1]}}}))" "$sid" "$n")
        out=$(curl -s --max-time 30 -X POST "$SUBSTRATE_API/api/a2a-sandboxes/$KAGENT_NS/$agent/" -H 'content-type: application/json' -d "$req")
        if printf '%s' "$out" | grep -q '"artifacts"'; then echo ok >> "$dir/$c"
        else echo refused >> "$dir/$c"; n=$((n-1)); sleep 0.5; fi
      done ) &
    pids+=($!)
  done
  local t0; t0=$(_now)
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 5
    printf '  t+%3.0fs  answered %3s  refused and retried %3s  running now %s\n' "$(_since "$t0")" \
      "$(cat "$dir"/* 2>/dev/null | grep -c '^ok' || true)" "$(cat "$dir"/* 2>/dev/null | grep -c '^refused' || true)" \
      "$(_status | python3 -c "import sys,json;print(sum(1 for a in json.load(sys.stdin)['data']['actors'] if a['status'] in ('Running','Resuming')))" 2>/dev/null || echo ?)"
  done
  wait "${pids[@]}" 2>/dev/null || true
  local ok ref; ok=$(cat "$dir"/* 2>/dev/null | grep -c '^ok' || true); ref=$(cat "$dir"/* 2>/dev/null | grep -c '^refused' || true)
  echo; echo "  == $ok turns answered by $clients actors in ${secs}s, $ref refused for a moment and retried =="
  for c in $(seq 1 "$clients"); do printf '  conversation %2s: %3s turns\n' "$c" "$(grep -c '^ok' "$dir/$c" 2>/dev/null || echo 0)"; done
  rm -rf "$dir"; return 0
}

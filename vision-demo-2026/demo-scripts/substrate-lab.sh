# substrate-lab.sh — the Agent Substrate lab's helpers, on top of substrate-lib.sh.
# The console runs every step in a fresh shell, so the one conversation the lab
# follows is kept in a file between steps.
#
#   wait-pool <pool> <n>       until the pool has n Running workers AND the api-server has them
#   show-template <agent>      the ActorTemplate kagent rendered, trimmed to what matters
#   wait-harness <name>        until an AgentHarness is Ready, printing each condition change
#   pool-templates <pool>      every ActorTemplate that runs on a pool, and who owns it
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

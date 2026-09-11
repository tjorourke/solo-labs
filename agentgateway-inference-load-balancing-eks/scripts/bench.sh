#!/usr/bin/env bash
# Run a load scenario from inside the cluster and print what each replica did.
#
#   ./scripts/bench.sh prefix
#   ./scripts/bench.sh mixed --requests 96 --concurrency 24
#   ./scripts/bench.sh skew  --label queue-only
#
# Everything after the scenario is passed straight to bench.py; run
# `./scripts/bench.sh mixed --help` for the full list.
#
# The script is piped in over kubectl exec rather than baked into an image or mounted
# from a ConfigMap, so the file you read in scripts/ is byte for byte the file that ran.
# A ConfigMap would be a step behind for up to a minute after every edit, which is a
# very confusing way to lose an afternoon.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

[ $# -ge 1 ] || die "usage: $0 {mixed|prefix|skew} [bench.py options]"

# Label the run with whatever profile is loaded, unless the caller named one. Comparing
# two runs whose scheduler you cannot identify afterwards is the commonest way to end up
# with numbers nobody trusts.
if ! printf '%s\n' "$@" | grep -q -- '--label'; then
  loaded="$(kc -n "$NS" get configmap "${POOL_RELEASE}-epp" \
    -o jsonpath='{.data.custom-plugins\.yaml}' 2>/dev/null \
    | grep -oE '^\s*-\s*pluginRef:.*' | sed 's/.*pluginRef: *//' | tr '\n' ',' | sed 's/,$//')"
  backend="$(kc -n "$NS" get httproute llm-route \
    -o jsonpath='{.spec.rules[0].backendRefs[0].kind}' 2>/dev/null)"
  set -- "$@" --label "${backend:-unknown} [${loaded:-no profile}]"
fi

# Mark the gateway log so the split below counts only this run's requests.
# Count with the SAME expression used to slice afterwards. Counting lines with grep -c
# and then slicing matches with grep -o is the kind of mismatch that silently returns an
# empty tail: one request line carries BOTH endpoint= and
# inferencepool.selected_endpoint=, so the two counts drift and the slice runs off the
# end, printing nothing at all rather than an error.
PICK_RE='inferencepool\.selected_endpoint=[^ ]+'
DIAL_RE='(^|[[:space:]])endpoint=[^ ]+'
gwlog() {
  kc -n "$NS" logs -l gateway.networking.k8s.io/gateway-name=inference-gateway --tail=-1 2>/dev/null
}
__log0="$(gwlog)"
before_lines=$(printf '%s\n' "$__log0" | grep -oE "$PICK_RE" | wc -l | tr -d ' ')
before_rr=$(printf '%s\n' "$__log0" | grep -oE "$DIAL_RE" | wc -l | tr -d ' ')

# -i, not -it. A TTY mangles the output when it is piped into a file or a notebook cell,
# and this output is meant to be kept.
kc -n "$NS" exec -i deploy/loadgen -- python3 - "$@" < "$LAB_ROOT/scripts/bench.py"
rc=$?

# THE GATEWAY'S OWN COUNT, which is the only trustworthy split for the skew scenario.
# bench.py reads each pod's counters, and in skew mode the background load is sent
# DIRECTLY to one replica, so that replica's counters include traffic the gateway never
# saw. The gateway only ever sees measured requests, so counting its log is the honest
# answer to "where did the requests I measured actually go".
#
# Slice to THIS run's lines before deciding which field is in play. The log keeps every
# earlier run, so testing whether the picker field exists at all says only "a pool run
# happened at some point", and the Service route would then be reported with the
# previous profile's numbers.
log_now="$(gwlog)"
picked="$(printf '%s\n' "$log_now" | grep -oE "$PICK_RE" | tail -n +$((before_lines + 1)) || true)"
dialled="$(printf '%s\n' "$log_now" | grep -oE "$DIAL_RE" | tail -n +$((before_rr + 1)) || true)"

echo
if [ -n "$picked" ]; then
  echo "gateway-side split (this run only, excludes any load sent direct to a replica):"
  printf '%s\n' "$picked" | sed 's/.*=//' | sort | uniq -c | sort -rn | sed 's/^/  /'
elif [ -n "$dialled" ]; then
  # No picker field on this run's lines, so the Service route was in force. The gateway
  # still logs the upstream it dialled, which is how the round-robin baseline gets a
  # split. The ABSENCE of the picker field is itself the evidence of which route ran.
  echo "gateway-side split (Service route: no picker ran, counting endpoint= instead):"
  printf '%s\n' "$dialled" | sed 's/.*=//' | sort | uniq -c | sort -rn | sed 's/^/  /'
else
  echo "gateway-side split: nothing new in the access log — check the gateway is serving."
fi
kc -n "$NS" get pods -l app=vllm -o custom-columns=NAME:.metadata.name,IP:.status.podIP --no-headers \
  | sed 's/^/  /'
exit $rc

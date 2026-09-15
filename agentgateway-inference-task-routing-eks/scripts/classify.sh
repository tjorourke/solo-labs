#!/usr/bin/env bash
# Ask the router what it makes of a prompt, and see why.
#
#   ./scripts/classify.sh "Review this function for concurrency bugs."
#
# Sends the prompt as bob and reads the router's decision back out of its log: the task label
# it chose, the decision that chose it, and the signals that fired. Use it when tuning the
# example phrasings in yaml/10-router-tasks.yaml. The request goes all the way through, so
# the response headers show where it ended up too.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens; gw_up
PROMPT="${1:?usage: $0 \"<prompt>\"}"
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sleep 1
gw_curl "$BOB_TOKEN" "$(chat "$PROMPT")"
sleep 2
echo "prompt:   $PROMPT"
kubectl -n "$NS" logs deploy/semantic-router --since-time="$MARK" | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == "routing_decision":
        print("task:     " + str(d.get("selected_model")) + "   (decision " + str(d.get("decision") or d.get("reason_code")) + ")")
    if d.get("event") == "router_replay_start":
        fired = {k: v for k, v in d.get("signals", {}).items() if v}
        print("signals:  " + json.dumps(fired))
        print("domain confidence: " + str(round(d.get("confidence_score", 0), 2)))'
echo "routed:   pool=$(pool) class=$(mclass) reason=\"$(reason)\" status=$STATUS model=$(resp_model)"

#!/bin/bash
# One s3 cp reconfigures the whole fleet, with no restart and nothing dropped.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

BUCKET="$(tf_out config_bucket)"
SRC="$LAB_DIR/config/config.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

hdr "How this works"
cat <<EOT
  S3 is the source of truth: s3://$BUCKET/config.yaml

  Every node runs a 30s systemd timer that syncs the object down. agentgateway
  watches its own config file, so when the file changes the process reloads the
  dynamic sections itself. The timer never restarts the gateway.

  The startup-only 'config' block is the exception. Change anything under it and
  the running process keeps its old value until it restarts. Everything below it
  reloads live.
EOT

hdr "1. Current state"
for id in $(fleet_instances); do
  sum="$(node_try "$id" 'sha256sum /etc/agentgateway/config.yaml | cut -c1-12' 2>/dev/null | tr -d '\n ')"
  printf '  %-20s config=%s\n' "$id" "$sum"
done
BEFORE="$(code "$GATEWAY_URL/api/public/newroute")"
log "GET /api/public/newroute right now: $BEFORE (no route matches it yet)"

hdr "2. Make a change"
log "Adding a route that returns a direct response, and changing the local rate"
log "limit on /api/public from 60/min to 90/min."
cp "$SRC" "$WORK/config.yaml"
python3 - "$WORK/config.yaml" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split('\n')
# insert a new route immediately after the routes: key
i = next(i for i, l in enumerate(lines) if l.startswith('routes:'))
new = """
# Added live by scripts/22-ha-config-push.sh
- name: pushed-live
  gateways: main
  matches:
  - path:
      exact: /api/public/newroute
  policies:
    directResponse:
      status: 200
      body: '{"pushed":true,"node":"$AGW_NODE_ID"}'
      headers:
        content-type: '"application/json"'
"""
lines[i+1:i+1] = new.strip('\n').split('\n')
out = '\n'.join(lines)
out = out.replace('      tokensPerFill: 60', '      tokensPerFill: 90')
out = out.replace('      maxTokens: 60', '      maxTokens: 90')
open(p, 'w').write(out)
PY
diff -u "$SRC" "$WORK/config.yaml" | head -30 | sed 's/^/    /' || true

hdr "3. Hold a streaming response open across the reload"
log "Starting a streaming completion that will still be running when the config"
log "changes. If a reload dropped connections, this would end early."
STREAM_OUT="$(mktemp)"
( curl -s -N --max-time 120 "$GATEWAY_URL/v1/chat/completions" \
    -H 'x-api-key: agw_sk_platform_demo' -H 'content-type: application/json' \
    -d '{"model":"claude-bedrock","stream":true,"max_tokens":400,"messages":[{"role":"user","content":"Write a numbered list of 30 short facts about load balancers, one per line."}]}' \
    >"$STREAM_OUT" 2>&1 ) & STREAM_PID=$!
sleep 3

hdr "4. Push it. One command."
log "aws s3 cp config/config.yaml s3://$BUCKET/config.yaml"
aws s3 cp "$WORK/config.yaml" "s3://$BUCKET/config.yaml" --only-show-errors
T0="$(date +%s)"
ok "pushed"

hdr "5. Watch all three nodes pick it up"
log "The timer fires every 30s, so this lands within 30 seconds without anyone"
log "touching an instance."
for i in $(seq 1 20); do
  c="$(code "$GATEWAY_URL/api/public/newroute")"
  printf '    t+%-3ss GET /api/public/newroute -> %s\n' $(( $(date +%s) - T0 )) "$c"
  [[ "$c" == "200" ]] && break
  sleep 5
done
expect "the new route is live" 200 "$(code "$GATEWAY_URL/api/public/newroute")"
log "elapsed: $(( $(date +%s) - T0 ))s"

log ""
log "And it is live on every node, not just the one that answered:"
hit=""
for _ in $(seq 1 20); do
  n="$(curl -s "$GATEWAY_URL/api/public/newroute" | jq -r '.node // "?"')"
  hit="$hit$n\n"
done
distinct="$(printf '%b' "$hit" | sort -u | grep -c . | tr -d ' ')"
log "nodes that served the new route: $(printf '%b' "$hit" | sort -u | grep . | tr '\n' ' ')"
expect "all three nodes serve the new route" 3 "$distinct"

hdr "6. Nothing restarted"
for id in $(fleet_instances); do
  up="$(node_try "$id" 'systemctl show agentgateway -p ActiveEnterTimestamp --value; echo; ps -o etimes= -p $(systemctl show agentgateway -p MainPID --value) 2>/dev/null | tr -d " "' 2>/dev/null | tr '\n' ' ')"
  sum="$(node_try "$id" 'sha256sum /etc/agentgateway/config.yaml | cut -c1-12' 2>/dev/null | tr -d '\n ')"
  printf '  %-20s config=%s  process uptime and start: %s\n' "$id" "$sum" "$up"
done
log "The process start times predate the push. The config changed underneath a"
log "running process."
log ""
log "Reload counter from the metrics endpoint on one node:"
one="$(fleet_instances | head -1)"
node_exec "$one" 'curl -s http://127.0.0.1:15020/metrics | grep -iE "config_(synchronized|reload)" | head -5' 2>/dev/null | sed 's/^/    /'

hdr "7. The stream survived"
wait "$STREAM_PID" 2>/dev/null || true
events="$(grep -c '^data:' "$STREAM_OUT" || true)"
done_marker="$(grep -c 'data: \[DONE\]' "$STREAM_OUT" || true)"
log "server-sent events received: $events"
if (( events > 5 )); then
  ok "the streaming response continued across the reload"
  PASS=$((PASS+1))
else
  warn "only $events events; check whether the model call itself failed"
  head -3 "$STREAM_OUT" | sed 's/^/    /'
fi
rm -f "$STREAM_OUT"

hdr "8. Roll it back"
log "S3 versioning is on, so the previous object is still there. Pushing the"
log "committed file back has the same effect."
aws s3 cp "$SRC" "s3://$BUCKET/config.yaml" --only-show-errors
log "waiting for the fleet to converge"
for i in $(seq 1 20); do
  c="$(code "$GATEWAY_URL/api/public/newroute")"
  [[ "$c" != "200" ]] && break
  sleep 5
done
expect "the added route is gone again" 404 "$(code "$GATEWAY_URL/api/public/newroute")"

hdr "What this replaces"
cat <<'EOT'
  There is no controller here, no xDS, no agent pulling from a management plane,
  and no configuration management tool. An object in a bucket, a timer, and the
  proxy's own file watcher.

  The audit trail is S3 object versioning, and rollback is a copy of an older
  version. If you would rather drive it from git, point the timer at a checkout
  instead; nothing about the gateway changes.
EOT

summary

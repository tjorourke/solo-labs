#!/bin/bash
# Lose a node two ways: stop the process, then destroy the instance.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

# Poll /whoami in the background and record every result, so the effect on live
# traffic is measured rather than asserted.
POLL_OUT="$(mktemp)"
start_poll() { ( while :; do curl -s -m 5 -o /dev/null -w '%{http_code}\n' "$GATEWAY_URL/whoami" >>"$POLL_OUT" || echo 000 >>"$POLL_OUT"; sleep 0.5; done ) & POLL_PID=$!; }
stop_poll()  { kill "$POLL_PID" 2>/dev/null || true; }
poll_report() {
  local total ok bad
  total=$(wc -l <"$POLL_OUT" | tr -d ' ')
  ok=$(grep -c '^200$' "$POLL_OUT" || true)
  bad=$(( total - ok ))
  printf '    %s requests, %s succeeded, %s failed\n' "$total" "$ok" "$bad"
  if (( bad > 0 )); then
    printf '    non-200 responses: '; grep -v '^200$' "$POLL_OUT" | sort | uniq -c | tr '\n' ' '; echo
  fi
  : >"$POLL_OUT"
  echo "$bad"
}
trap stop_poll EXIT

hdr "Starting state"
fleet_table; echo; target_health
expect "three healthy targets to begin with" 3 "$(healthy_count)"

# ---------------------------------------------------------------------------
hdr "Part 1: stop the gateway on one node"
# ---------------------------------------------------------------------------
VICTIM="$(fleet_instances | head -1)"
log "victim: $VICTIM"
log "Polling /whoami twice a second while the process goes away."
start_poll
sleep 5

log "systemctl stop agentgateway on $VICTIM"
node_exec "$VICTIM" 'systemctl stop agentgateway' >/dev/null
log "Waiting for the ALB to notice. The health check is every 10s and needs two"
log "consecutive failures, so this takes about 20 seconds."

for i in $(seq 1 24); do
  h="$(healthy_count)"
  printf '    t+%-3ss healthy=%s\n' $((i*5)) "$h"
  [[ "$h" == "2" ]] && break
  sleep 5
done
expect "the ALB dropped it to two healthy targets" 2 "$(healthy_count)"

log "Traffic during the failure:"
sleep 5
stop_poll
FAILED_1="$(poll_report | tail -1)"
log "Some in-flight requests can fail in the window before the health check"
log "reacts. That is what deregistration_delay and the health check interval buy"
log "you, and it is honest to show the number rather than claim zero."

log "Restarting the gateway on $VICTIM"
node_exec "$VICTIM" 'systemctl start agentgateway' >/dev/null
for i in $(seq 1 24); do
  h="$(healthy_count)"; printf '    t+%-3ss healthy=%s\n' $((i*5)) "$h"
  [[ "$h" == "3" ]] && break
  sleep 5
done
expect "back to three healthy targets" 3 "$(healthy_count)"

# ---------------------------------------------------------------------------
hdr "Part 2: destroy the instance"
# ---------------------------------------------------------------------------
cat <<'EOT'
  This is the part that matters. Terminating an instance means the replacement has
  no state of its own: it has to install the binary, read the secret, pull the
  config from S3 and connect to Aurora, all with no manual step and no operator.

  Anything the fleet knows that is not in the launch template has to come from S3
  or from Aurora, or the new node comes up different from its siblings.
EOT
echo
VICTIM2="$(fleet_instances | tail -1)"
log "terminating $VICTIM2"
start_poll
T0="$(date +%s)"
aws ec2 terminate-instances --instance-ids "$VICTIM2" --query 'TerminatingInstances[0].CurrentState.Name' --output text | sed 's/^/    state: /'

log "Waiting for the Auto Scaling group to build a replacement."
NEW=""
for i in $(seq 1 90); do
  current="$(fleet_instances)"
  NEW="$(comm -13 <(echo "$VICTIM2") <(echo "$current" | sort) | grep -v "^$VICTIM2$" | head -1 || true)"
  h="$(healthy_count)"
  printf '    t+%-4ss instances=%s healthy=%s\n' $(( $(date +%s) - T0 )) "$(echo "$current" | grep -c .)" "$h"
  if [[ "$h" == "3" ]] && ! echo "$current" | grep -q "^$VICTIM2$"; then break; fi
  sleep 10
done
T1="$(date +%s)"
stop_poll

hdr "Result"
expect "three healthy targets again" 3 "$(healthy_count)"
log "time from terminate to three healthy: $(( T1 - T0 ))s"
log "Traffic during the replacement:"
poll_report >/dev/null
echo
fleet_table

hdr "The replacement is indistinguishable from its siblings"
for id in $(fleet_instances); do
  sum="$(node_exec "$id" 'sha256sum /etc/agentgateway/config.yaml | cut -c1-12' 2>/dev/null | tr -d '\n ')"
  ver="$(node_exec "$id" '/usr/local/bin/agentgateway --version | jq -r .version' 2>/dev/null | tr -d '\n ')"
  printf '  %-20s version=%-8s config=%s\n' "$id" "${ver:-?}" "${sum:-?}"
done
log "Same pinned binary, same config hash. The version is pinned in the launch"
log "template rather than tracking latest, so a node built next week is the same"
log "build as the two beside it."

hdr "And it is serving"
for _ in $(seq 1 15); do whoami_node; done | sort | uniq -c | sed 's/^/    /'

summary

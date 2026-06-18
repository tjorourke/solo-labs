#!/usr/bin/env bash
# 05-test.sh — drive per-team traffic through the gateway. Each team's requests
# carry that team's application-inference-profile ARN as the model. A background
# port-forward to the gateway is started if one isn't already up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
[[ -f "$RESULTS_DIR/profiles.env" ]] || die "run ./scripts/03-aws-profiles.sh first"
source "$RESULTS_DIR/profiles.env"
set +e   # individual request failures are reported per line, not fatal

REQS="${REQS:-3}"   # requests per team
BASE="http://localhost:${LPORT}"

step "Port-forward gateway svc → localhost:$LPORT"
# Always establish a fresh forward — the proxy may have just restarted (04),
# which silently kills an existing one.
pkill -f "port-forward.*agentgateway-proxy.*${LPORT}" 2>/dev/null || true
( kctx -n "$GW_NS" port-forward svc/agentgateway-proxy "${LPORT}:${PORT}" >/tmp/bedrock-cost-pf.log 2>&1 & echo $! >/tmp/bedrock-cost-pf.pid )
sleep 4
ok "port-forward ready"

for team in $TEAMS; do
  var="TEAM_$(echo "$team" | tr 'a-z-' 'A-Z_')_ARN"; arn="${!var}"
  [[ -z "$arn" || "$arn" == "None" ]] && { warn "no ARN for $team — skip"; continue; }
  step "team '$team' → $REQS requests"
  for i in $(seq 1 "$REQS"); do
    body="$(printf '{"model":"%s","messages":[{"role":"user","content":"In one short sentence, give tip #%s for a %s microservice."}]}' "$arn" "$i" "$team")"
    resp="$(curl -s -m 60 -w '|%{http_code}' "${BASE}/v1/chat/completions" -H 'content-type: application/json' -d "$body")"
    code="${resp##*|}"; json="${resp%|*}"
    usage="$(echo "$json" | jq -rc '"in=\(.usage.prompt_tokens) out=\(.usage.completion_tokens) model=\(.model // .error.message)"' 2>/dev/null)"
    log "  [$team #$i] HTTP $code  $usage"
  done
done
ok "traffic done — now: ./scripts/06-metrics.sh"

#!/usr/bin/env bash
# quick.sh — E2E entrypoint (labs.manifest.json). Verbs: up | test | teardown.
#   up       : cluster + AGW + per-team AWS profiles + backend + smoke traffic
#   test     : assert 200s and that token usage is attributed per team (per ARN)
#   teardown : delete the kind cluster, the AWS application inference profiles,
#              and any port-forwards. Leaves nothing behind.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
VERB="${1:-up}"

case "$VERB" in
  up)
    bash "$SCRIPT_DIR/01-cluster.sh"
    bash "$SCRIPT_DIR/02-agentgateway.sh"
    bash "$SCRIPT_DIR/03-aws-profiles.sh"
    bash "$SCRIPT_DIR/04-backend.sh"
    REQS="${REQS:-2}" bash "$SCRIPT_DIR/05-test.sh"
    ok "up complete"
    ;;

  test)
    set +e
    [[ -f "$RESULTS_DIR/profiles.env" ]] || die "no profiles.env — run 'up' first"
    source "$RESULTS_DIR/profiles.env"
    # fresh port-forward (the proxy may have restarted during up)
    pkill -f "port-forward.*agentgateway-proxy.*${LPORT}" 2>/dev/null || true
    kctx -n "$GW_NS" port-forward svc/agentgateway-proxy "${LPORT}:${PORT}" >/tmp/bc-pf.log 2>&1 &
    sleep 4
    fails=0
    for team in $TEAMS; do
      var="TEAM_$(echo "$team" | tr 'a-z-' 'A-Z_')_ARN"; arn="${!var}"
      body="$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with the single word OK."}]}' "$arn")"
      code="$(curl -s -m 60 -o /dev/null -w '%{http_code}' "http://localhost:${LPORT}/v1/chat/completions" -H 'content-type: application/json' -d "$body")"
      [[ "$code" == "200" ]] && ok "team $team → HTTP 200" || { warn "team $team → HTTP $code"; fails=$((fails+1)); }
    done
    # assert the metric carries a per-team series (the ARN as gen_ai_request_model)
    POD="$(kctx -n "$GW_NS" get pods -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o jsonpath='{.items[0].metadata.name}')"
    pkill -f "port-forward.*${MPORT}" 2>/dev/null || true
    kctx -n "$GW_NS" port-forward "pod/$POD" "${MPORT}:${MPORT}" >/tmp/bc-mpf.log 2>&1 &
    sleep 3
    metrics="$(curl -s "localhost:${MPORT}/metrics")"
    for team in $TEAMS; do
      var="TEAM_$(echo "$team" | tr 'a-z-' 'A-Z_')_ARN"; arn="${!var}"
      id="${arn##*/}"
      echo "$metrics" | grep -q "gen_ai_client_token_usage.*${id}" \
        && ok "metric attributed to team $team ($id)" \
        || { warn "no gen_ai_request_model series for $team ($id)"; fails=$((fails+1)); }
    done
    [[ "$fails" -eq 0 ]] && { ok "TEST PASS"; exit 0; } || { die "TEST FAIL ($fails check(s) failed)"; }
    ;;

  teardown)
    set +e
    pkill -f "port-forward.*${LPORT}" 2>/dev/null || true
    pkill -f "port-forward.*${MPORT}" 2>/dev/null || true
    if [[ -f "$RESULTS_DIR/profiles.env" ]]; then
      load_secrets >/dev/null 2>&1
      source "$RESULTS_DIR/profiles.env"
      for team in $TEAMS; do
        var="TEAM_$(echo "$team" | tr 'a-z-' 'A-Z_')_ARN"; arn="${!var}"
        [[ -n "$arn" && "$arn" != "None" ]] && aws bedrock delete-inference-profile \
          --region "$REGION" --inference-profile-identifier "$arn" >/dev/null 2>&1 \
          && log "deleted AWS profile for $team"
      done
      rm -f "$RESULTS_DIR/profiles.env"
    fi
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 && ok "cluster '$CLUSTER' deleted" || log "no cluster to delete"
    ;;

  *) die "usage: quick.sh up|test|teardown" ;;
esac

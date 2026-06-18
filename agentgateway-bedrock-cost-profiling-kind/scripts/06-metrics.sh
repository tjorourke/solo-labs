#!/usr/bin/env bash
# 06-metrics.sh — show per-team token attribution from agentgateway's
# gen_ai_request_model metric. Maps each team's application-inference-profile
# ARN back to the team name so the split is readable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
[[ -f "$RESULTS_DIR/profiles.env" ]] || die "run ./scripts/03-aws-profiles.sh first"
source "$RESULTS_DIR/profiles.env"

POD="$(kctx -n "$GW_NS" get pods -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -z "$POD" ]] && POD="$(kctx -n "$GW_NS" get pods -o name | grep agentgateway-proxy | grep -v enterprise | head -1 | sed 's#pod/##')"
step "Scraping /metrics from $POD"
pkill -f "port-forward.*${POD}.*${MPORT}" 2>/dev/null || true
( kctx -n "$GW_NS" port-forward "pod/$POD" "${MPORT}:${MPORT}" >/tmp/bedrock-cost-mpf.log 2>&1 & echo $! >/tmp/bedrock-cost-mpf.pid )
sleep 3
mkdir -p "$RESULTS_DIR"
curl -s "localhost:${MPORT}/metrics" | grep 'gen_ai_client_token_usage_sum' > "$RESULTS_DIR/metrics.txt"

echo >&2
step "Per-team token totals (from gen_ai_request_model label)"
python3 - "$RESULTS_DIR/metrics.txt" "$RESULTS_DIR/profiles.env" <<'PY' >&2
import re,sys
lines=open(sys.argv[1]).read().splitlines()
# build arn->team map from profiles.env (TEAM_X_ARN="arn...")
team={}
for l in open(sys.argv[2]):
    m=re.match(r'TEAM_(.+)_ARN="(.+)"',l.strip())
    if m: team[m.group(2)]=m.group(1).lower().replace('_','-')
agg={}
for l in lines:
    mt=re.search(r'gen_ai_token_type="([^"]+)"',l)
    mm=re.search(r'gen_ai_request_model="([^"]+)"',l)
    mv=re.search(r'}\s+([0-9.]+)$',l)
    if not (mt and mm and mv): continue
    tt,model,val=mt.group(1),mm.group(1),float(mv.group(1))
    label=team.get(model, model[:40])
    agg.setdefault(label,{}).setdefault(tt,0.0)
    agg[label][tt]+=val
print(f"{'team / model':24} {'input':>8} {'output':>8} {'cache_read':>11}")
print('-'*54)
for k in sorted(agg):
    r=agg[k]
    print(f"{k:24} {r.get('input',0):8.0f} {r.get('output',0):8.0f} {r.get('input_cache_read',0):11.0f}")
PY

echo >&2
log "PromQL for Grafana (per-team output tokens, last hour):"
log "  sum by (gen_ai_request_model)(increase(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type=\"output\"}[1h]))"

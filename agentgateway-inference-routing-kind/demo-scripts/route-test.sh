#!/usr/bin/env bash
# route-test.sh — fire N chat-completion requests through the gateway and report
# which model-server replica the endpoint picker chose. Self-contained: opens a
# temporary port-forward, sends the traffic, and tallies which replica served each
# request from the gateway's own access log (selected_endpoint), tears the PF down.
#
#   ./demo-scripts/route-test.sh [count]   (default 8)
set -Eeuo pipefail
CTX="${CTX:-kind-inference}"; NS="${NS:-inference}"; N="${1:-8}"; PORT="${PORT:-18080}"
PROMPT="${PROMPT:-Explain Kubernetes in one sentence.}"

gw() { kubectl --context "$CTX" -n "$NS" logs deploy/inference-gateway --tail=-1 2>/dev/null | grep -c "selected_endpoint=$1:"; }
aip=$(kubectl --context "$CTX" -n "$NS" get pod -l replica=pool-a -o jsonpath='{.items[0].status.podIP}')
bip=$(kubectl --context "$CTX" -n "$NS" get pod -l replica=pool-b -o jsonpath='{.items[0].status.podIP}')

kubectl --context "$CTX" -n "$NS" port-forward svc/inference-gateway "${PORT}:80" >/tmp/agw-inference-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
sleep 4

a0=$(gw "$aip"); b0=$(gw "$bip")
sent=0; ok=0
for i in $(seq 1 "$N"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "localhost:${PORT}/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"base-model\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}]}")
  sent=$((sent+1)); [[ "$code" == "200" ]] && ok=$((ok+1))
done
sleep 1
a=$(( $(gw "$aip") - a0 )); b=$(( $(gw "$bip") - b0 ))
kva=$(kubectl --context "$CTX" -n "$NS" get cm sim-pool-a -o jsonpath='{.data.config\.yaml}' 2>/dev/null | awk '/kv-cache-usage/{print $2}')
kvb=$(kubectl --context "$CTX" -n "$NS" get cm sim-pool-b -o jsonpath='{.data.config\.yaml}' 2>/dev/null | awk '/kv-cache-usage/{print $2}')

echo "sent ${sent}, ${ok} x HTTP 200"
echo "  pool-a (kv-cache=${kva:-?}): ${a} requests"
echo "  pool-b (kv-cache=${kvb:-?}): ${b} requests"

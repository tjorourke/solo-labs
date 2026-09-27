# inference-helpers.sh — the commands the inference routing lab reuses.
# Sourced by the console for every step (needs $CTX and $NS exported).
#
#   signals                               what the picker sees on each replica
#   route_test [N]                        N requests, then which replica served them
#   set_metrics <a|b> <kv> <waiting> <running>   re-pin one replica's gauges
#
# Requests go to localhost:18080, one port-forward to the gateway kept up across
# steps. It is started here if nothing is listening yet.

if ! nc -z localhost 18080 2>/dev/null; then
  nohup kubectl --context "$CTX" -n "$NS" port-forward svc/inference-gateway 18080:80 \
    >/tmp/agw-inf-pf.log 2>&1 </dev/null &
  disown
  for _ in $(seq 1 20); do nc -z localhost 18080 2>/dev/null && break; sleep 0.5; done
fi

signals() {
  local r cfg
  for r in a b; do
    cfg=$(kubectl --context "$CTX" -n "$NS" get cm sim-pool-$r -o jsonpath='{.data.config\.yaml}')
    printf '  pool-%s: kv-cache=%s  queue=%s\n' "$r" \
      "$(echo "$cfg" | awk '/kv-cache-usage/{print $2}')" \
      "$(echo "$cfg" | awk '/waiting-requests/{print $2}')"
  done
}

# which endpoint the gateway routed to, straight from its access log (selected_endpoint)
# (grep -c exits 1 on a zero count, which would stop a step running under set -e)
_gw() { kubectl --context "$CTX" -n "$NS" logs deploy/inference-gateway --tail=-1 2>/dev/null | grep -c "selected_endpoint=$1:" || true; }

route_test() {
  local n="${1:-8}" i aip bip a0 b0
  aip=$(kubectl --context "$CTX" -n "$NS" get pod -l replica=pool-a -o jsonpath='{.items[0].status.podIP}')
  bip=$(kubectl --context "$CTX" -n "$NS" get pod -l replica=pool-b -o jsonpath='{.items[0].status.podIP}')
  a0=$(_gw "$aip"); b0=$(_gw "$bip")
  for i in $(seq 1 "$n"); do
    curl -s -o /dev/null localhost:18080/v1/chat/completions -H 'content-type: application/json' \
      -d '{"model":"base-model","messages":[{"role":"user","content":"Explain Kubernetes in one sentence."}]}'
  done
  sleep 1
  printf '  %s requests -> pool-a served %s, pool-b served %s\n' "$n" "$(( $(_gw "$aip") - a0 ))" "$(( $(_gw "$bip") - b0 ))"
}

set_metrics() {  # <a|b> <kv 0..1> <waiting> <running>
  printf 'model: base-model\nport: 8000\nfake-metrics:\n  kv-cache-usage: %s\n  waiting-requests: %s\n  running-requests: %s\n' "$2" "$3" "$4" \
    | kubectl --context "$CTX" -n "$NS" create cm sim-pool-$1 --from-literal=config.yaml="$(cat)" --dry-run=client -o yaml \
    | kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null
  kubectl --context "$CTX" -n "$NS" rollout restart deploy/vllm-pool-$1 >/dev/null
  kubectl --context "$CTX" -n "$NS" rollout status deploy/vllm-pool-$1 --timeout=90s >/dev/null
  printf '  pool-%s -> kv-cache=%s queue=%s\n' "$1" "$2" "$3"
}

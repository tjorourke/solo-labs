#!/usr/bin/env bash
# set-kv.sh — pin a model-server replica's fake KV-cache / queue gauges, then
# restart it so the endpoint picker re-scores. This is the "flip on cue" knob:
# saturate the replica that is currently serving and watch traffic move.
#
#   ./demo-scripts/set-kv.sh <a|b> <kv-cache 0..1> [waiting] [running]
# e.g.
#   ./demo-scripts/set-kv.sh a 0.95 9 6     # pool-a becomes HOT
#   ./demo-scripts/set-kv.sh b 0.05 0 1     # pool-b becomes COLD
set -Eeuo pipefail
CTX="${CTX:-kind-inference}"; NS="${NS:-inference}"
which="${1:?replica: a or b}"; kv="${2:?kv-cache 0..1}"; waiting="${3:-0}"; running="${4:-1}"
case "$which" in
  a) cm=sim-pool-a; dep=vllm-pool-a ;;
  b) cm=sim-pool-b; dep=vllm-pool-b ;;
  *) echo "replica must be 'a' or 'b'" >&2; exit 1 ;;
esac
cfg="model: base-model
port: 8000
fake-metrics:
  kv-cache-usage: ${kv}
  waiting-requests: ${waiting}
  running-requests: ${running}
"
kubectl --context "$CTX" -n "$NS" create configmap "$cm" \
  --from-literal=config.yaml="$cfg" --dry-run=client -o yaml \
  | kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null
kubectl --context "$CTX" -n "$NS" rollout restart deploy/"$dep" >/dev/null
kubectl --context "$CTX" -n "$NS" rollout status deploy/"$dep" --timeout=90s >/dev/null
echo "pool-$which -> kv-cache=${kv} waiting=${waiting} running=${running} (restarted)"
echo "give the EPP ~5s to re-scrape, then re-run the route test."

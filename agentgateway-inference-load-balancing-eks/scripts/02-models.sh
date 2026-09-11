#!/usr/bin/env bash
# Bring up the model: one StatefulSet, two replicas, one GPU card each.
#
#   ./scripts/02-models.sh
#
# First run pulls about 31 GB of weights onto each replica's own volume. They download
# in parallel (podManagementPolicy: Parallel), so allow roughly 20 minutes rather than
# 40, then a 9 GB image pull on a cold node, then load and CUDA graph capture.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

step "checking there are two GPU nodes to balance across"
# A lab with one card still comes up, serves, and proves nothing: the Endpoint Picker
# scores a pool of one and always returns it. Say so now rather than after the weights
# have downloaded.
gpu_nodes=$(kc get nodes -l role=gpu \
  -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | grep -c '^1$' || true)
if [ "${gpu_nodes:-0}" -lt 2 ]; then
  warn "only ${gpu_nodes:-0} node(s) advertising a GPU. Bring the pair up with: ./scripts/gpu.sh up"
  die "need two GPU nodes; there is nothing to load balance across one"
fi
ok "$gpu_nodes GPU nodes ready"

step "model servers (first run pulls ~31 GB per replica, in parallel)"
kc apply -f "$LAB_ROOT/yaml/01-model.yaml" >/dev/null
ok "StatefulSet vllm applied"

step "waiting for both replicas (up to 40m on a cold cluster)"
# rollout status on a StatefulSet waits for BOTH replicas to be Ready, which is what is
# wanted, and it fails loudly rather than timing out silently.
kc -n "$NS" rollout status statefulset/vllm --timeout=2400s

step "load generator"
kc apply -f "$LAB_ROOT/yaml/30-loadgen.yaml" >/dev/null
kc -n "$NS" rollout status deploy/loadgen --timeout=300s >/dev/null
ok "loadgen ready"

step "what each replica advertises"
for i in 0 1; do
  printf '  vllm-%s  ' "$i" >&2
  kc -n "$NS" exec "vllm-$i" -c vllm -- python3 -c \
    "import json,urllib.request;print([m['id'] for m in json.load(urllib.request.urlopen('http://localhost:8000/v1/models'))['data']])" \
    2>/dev/null || echo "not ready" >&2
done

step "confirming prefix caching is actually on"
# Not from a flag. The V1 engine turns prefix caching on by default and the flag to
# force it has moved and been renamed more than once, so the honest check is whether the
# counters exist at all. Without them, half this lab measures nothing.
if kc -n "$NS" exec vllm-0 -c vllm -- \
     python3 -c "import urllib.request,sys;sys.exit(0 if b'vllm:prefix_cache_queries' in urllib.request.urlopen('http://localhost:8000/metrics').read() else 1)" 2>/dev/null; then
  ok "vllm:prefix_cache_queries present — prefix caching is on"
else
  warn "vllm:prefix_cache_queries missing. The prefix scenario will report n/a hit rates."
fi

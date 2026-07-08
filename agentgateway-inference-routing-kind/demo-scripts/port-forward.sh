#!/usr/bin/env bash
# port-forward.sh — expose the inference gateway on localhost:18080 (foreground;
# Ctrl-C to stop). Then, in another shell:
#   curl localhost:18080/v1/chat/completions -H 'content-type: application/json' \
#     -d '{"model":"base-model","messages":[{"role":"user","content":"hello"}]}'
set -Eeuo pipefail
CTX="${CTX:-kind-inference}"; NS="${NS:-inference}"; PORT="${PORT:-18080}"
echo "inference gateway -> http://localhost:${PORT}  (Ctrl-C to stop)"
exec kubectl --context "$CTX" -n "$NS" port-forward svc/inference-gateway "${PORT}:80"

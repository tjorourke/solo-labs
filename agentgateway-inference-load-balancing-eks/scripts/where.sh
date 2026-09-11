#!/usr/bin/env bash
# Which replica actually served the last N requests, read off the gateway.
#
#   ./scripts/where.sh          the last 20
#   ./scripts/where.sh 100
#
# bench.py answers the same question from the model servers' own counters, which is the
# better evidence for a whole run. This answers it per request, from the gateway's side,
# which is the better evidence for "show me it happening".
#
# inferencepool.selected_endpoint is the field the gateway writes when it used the
# Endpoint Picker's answer. On the Service route it is absent, because there was no
# picker: that absence is how you tell the two routes apart from the log alone.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

N="${1:-20}"

lines="$(kc -n "$NS" logs -l gateway.networking.k8s.io/gateway-name=inference-gateway \
          --tail="$N" 2>/dev/null | grep -E 'inferencepool.selected_endpoint=|endpoint=' || true)"

if [ -z "$lines" ]; then
  warn "no request lines in the gateway log."
  log "Either nothing has been sent yet, or the access log has rolled. Send one with:"
  log "  ./scripts/bench.sh mixed --requests 4 --concurrency 2"
  exit 0
fi

echo "per request:"
printf '%s\n' "$lines" \
  | grep -oE 'inferencepool.selected_endpoint=[^ ]+|endpoint=[^ ]+' \
  | sed 's/^/  /'

echo
echo "totals:"
printf '%s\n' "$lines" \
  | grep -oE 'inferencepool.selected_endpoint=[^ ]+' \
  | sort | uniq -c | sort -rn | sed 's/^/  /'

# The pod IPs in the log are not memorable. Print the mapping so the counts above can be
# read as "replica 0" and "replica 1" without a second lookup.
echo
echo "which IP is which replica:"
kc -n "$NS" get pods -l app=vllm -o custom-columns=NAME:.metadata.name,IP:.status.podIP --no-headers \
  | sed 's/^/  /'

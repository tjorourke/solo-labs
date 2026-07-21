#!/usr/bin/env bash
# logs.sh — read ztunnel's identity-aware L4 access logs.
#
# ztunnel logs every connection with the peer SPIFFE identities and the
# outcome, so you can see authorization decisions by identity, at L4, with no
# waypoint. This tails all ztunnel pods, keeps lines about identity-demo, and
# projects the fields that matter: direction, src identity, dst service, and
# whether the connection was allowed or denied.
#
#   scripts/logs.sh              # last 5 minutes, then follow
#   scripts/logs.sh 200          # last 200 lines per ztunnel, then follow
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
TAIL="${1:-}"
SINCE_ARGS=(--since=5m); [[ -n "$TAIL" ]] && SINCE_ARGS=(--tail="$TAIL")

log "Following ztunnel access logs for '$NS_APP' (Ctrl-C to stop). src.identity is the caller's SVID."
kc -n "$ISTIO_SYSTEM_NS" logs -l app=ztunnel -c istio-proxy --prefix -f "${SINCE_ARGS[@]}" 2>/dev/null \
  | grep --line-buffered "$NS_APP" \
  | grep --line-buffered -E 'access|connection complete|RBAC|denied|error' \
  | while IFS= read -r line; do
      json="${line#*\{}"; json="{${json}"
      echo "$json" | jq -rc 'select(.src.identity != null or .["src.identity"] != null)
        | { dir: (.direction // "-"),
            src: (.src.identity // .["src.identity"] // "-"),
            dst: (.dst.service // .["dst.service"] // .dst.identity // "-"),
            port: (.["dst.port"] // .dst.port // "-"),
            result: (if (.error // "") == "" then "ALLOW" else ("DENY: " + (.error|tostring)) end) }' 2>/dev/null \
      || echo "$line"
    done

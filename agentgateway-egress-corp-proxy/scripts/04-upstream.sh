#!/usr/bin/env bash
# 04-upstream.sh — the destination API the gateway is trying to reach.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Deploying the destination API (HTTPS, signed by upstream-ca)"
kc apply -f "$SCRIPT_DIR/../$YAML_DIR/10-upstream.yaml" >/dev/null
wait_deploy "$UPSTREAM_NS" api
ok "https://${API_HOST} is serving"

step "Destination ready"
echo "  Next: ./scripts/05-proxies.sh" >&2

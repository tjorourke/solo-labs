#!/usr/bin/env bash
# 04-migrate-l4.sh — migrate the L4-only namespace (petstore-data) to ambient.
# No waypoint: ztunnel alone enforces STRICT mTLS and the identity-based L4
# AuthorizationPolicy. Enrol, stop injection, restart — pods come back with no
# sidecar and Redis keeps enforcing exactly the same rule.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

step "Enrolling $NS_DATA (ambient on, injection off) — no waypoint needed"
kc label ns "$NS_DATA" istio.io/dataplane-mode=ambient istio-injection- --overwrite >/dev/null
kc -n "$NS_DATA" rollout restart deploy/redis >/dev/null
kc -n "$NS_DATA" rollout status deploy/redis --timeout=120s >/dev/null
ok "redis re-rolled with no sidecar (1/1)"
kc get pods -n "$NS_DATA" 2>/dev/null

echo
ok "$NS_DATA is on ambient. ztunnel enforces mTLS + L4 authz with no waypoint."
log "verify allow/deny with ./scripts/health-check.sh"
log "next: ./scripts/05-migrate-l7.sh"

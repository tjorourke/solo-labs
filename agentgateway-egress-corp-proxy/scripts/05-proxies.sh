#!/usr/bin/env bash
# 05-proxies.sh — the forward proxies: plain, authenticating, TLS-fronted,
# and the TLS-inspecting one.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# The proxies resolve the air-gapped destination through /etc/hosts, so they
# need the destination Service's ClusterIP at apply time.
API_IP="$(kc -n "$UPSTREAM_NS" get svc api -o jsonpath='{.spec.clusterIP}')"
[[ -n "$API_IP" ]] || die "destination Service $UPSTREAM_NS/api has no ClusterIP — run 04-upstream.sh first"
log "destination ClusterIP $API_IP → ${AIRGAP_HOST} inside the proxies"

step "Deploying Squid (plain, authenticating, TLS-fronted)"
sed "s/ACME_API_IP/${API_IP}/g" "$SCRIPT_DIR/../$YAML_DIR/20-squid.yaml" | kc apply -f - >/dev/null
wait_deploy "$EGRESS_NS" squid
wait_deploy "$EGRESS_NS" squid-auth
wait_deploy "$EGRESS_NS" squid-tls
ok "squid:3128, squid-auth:3128, squid-tls:3130"

step "Deploying the inspecting proxy (mitmproxy, re-signs with corp-ca)"
kc apply -f "$SCRIPT_DIR/../$YAML_DIR/21-mitmproxy.yaml" >/dev/null
wait_deploy "$EGRESS_NS" mitm
ok "mitm:8080"

step "Proxies ready"
echo "  Next: ./scripts/06-gateway.sh" >&2

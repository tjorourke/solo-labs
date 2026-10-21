#!/usr/bin/env bash
# 02-deploy-apps.sh: the shop app and the legacy caller, then enrolment.
#
#   1. kubectl apply: namespaces, catalog, checkout, reporting, legacy
#   2. probe: everyone gets 200, nothing is in the mesh yet
#   3. ONE label on the shop namespace enrols it in ambient. No restart.
#   4. probe again: still 200 everywhere, but the shop traffic is now mTLS
#      through ztunnel, and ztunnel's access log shows both identities.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kubectl

step "Deploying the shop app and the legacy caller"
show kc apply -f "$LAB_ROOT/yaml/00-namespaces.yaml" -f "$LAB_ROOT/yaml/10-apps/"
for d in catalog checkout reporting; do
  kc -n "$NS_SHOP" rollout status "deploy/$d" --timeout=180s >/dev/null
done
kc -n "$NS_LEGACY" rollout status deploy/legacy --timeout=180s >/dev/null
ok "catalog, checkout, reporting (shop) and legacy are running, 1/1 each: no sidecars anywhere"

step "Before enrolment: plain Kubernetes networking"
"$SCRIPT_DIR/probe.sh" --no-jwt
show ic ztunnel-config workloads --workload-namespace "$NS_SHOP"
log "PROTOCOL is TCP for every shop pod: ztunnel knows about them but is not in their path."

step "Enrol the shop namespace in ambient: one label, no restart"
show kc label namespace "$NS_SHOP" istio.io/dataplane-mode=ambient --overwrite
sleep 3
show ic ztunnel-config workloads --workload-namespace "$NS_SHOP"
log "PROTOCOL is now HBONE: the CNI node agent redirected the running pods to ztunnel in place."

step "After enrolment: same answers, now over mTLS"
"$SCRIPT_DIR/probe.sh" --no-jwt

catalog_pod="$(kc -n "$NS_SHOP" get pod -l app=catalog -o jsonpath='{.items[0].metadata.name}')"
zt="$(ztunnel_for "$NS_SHOP" "$catalog_pod")"
log "ztunnel's access log on catalog's node ($zt), the last checkout -> catalog connection:"
kc -n "$ISTIO_SYSTEM_NS" logs "$zt" --since=2m 2>/dev/null \
  | grep '"dst.service":"catalog' | grep '"src.workload":"checkout' | tail -1 \
  | python3 -c 'import sys,json
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: continue
    for k in ("src.workload","src.identity","dst.service","dst.identity","dst.hbone_addr"):
        print(f"    {k:16} {d.get(k)}")' || true

echo
ok "shop is in the mesh. Every hop between its pods is mTLS with a SPIFFE identity on each end."
log "Nothing is denied yet. Next: ./scripts/03-strict-mtls.sh"

#!/usr/bin/env bash
# 09-certs.sh — scenario 7: certificate rotation. Show the chain a workload
# holds and how long it lives, then rotate eks-a's intermediate CA under live
# traffic: new cacerts, istiod reloads it (AUTO_RELOAD_PLUGIN_CERTS), ztunnel
# picks up the new issuer at its next renewal. Cross-cluster keeps working
# because the shared root did not change.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require openssl
require_aws; require_contexts; require_istioctl
A="$CLUSTER_A"; B="$CLUSTER_B"
CERTS="$STATE_DIR/certs"

leaf_of() {  # leaf_of <ctx> <identity-substring> -> PEM of the first cert for that identity
  local ctx="$1" who="$2" zt
  zt="$(kubectl --context "$ctx" -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')"
  "$ISTIOCTL" --context "$ctx" ztunnel-config certificate "$zt.istio-system" -o json \
    | python3 -c "import json,sys,base64
for c in json.load(sys.stdin):
    if '$who' in c.get('identity',''):
        print(base64.b64decode(c['certChain'][0]['pem']).decode()); sys.exit(0)
sys.exit(1)"
}
show_cert() { openssl x509 -noout -subject -issuer -serial -dates -ext subjectAltName 2>/dev/null | sed 's/^/     /'; }

step "[$A] the catalog workload certificate (leaf): who, issuer, lifetime"
leaf_of "$A" "sa/catalog" | show_cert
echo "  ($A ztunnel requests 30 minute certificates in this lab, SECRET_TTL; the default is 24h)"
step "[$B] same identity in the other cluster, default lifetime"
leaf_of "$B" "sa/catalog" | show_cert

step "Rotation under load: frontend keeps calling catalog every 2s; count errors before/after"
BEFORE="$(kubectl --context "$A" -n "$APP_NS" logs deploy/frontend --since=1m | grep -c UNREACHABLE || true)"
OLD_ISSUER_SERIAL="$(openssl x509 -noout -serial -in "$CERTS/${A}-ca.crt" | cut -d= -f2)"
log "current intermediate serial: $OLD_ISSUER_SERIAL"

step "[$A] new intermediate CA, signed by the SAME offline root"
make_intermediate() {
  local name="$1" suffix="$2" base="$CERTS/${1}${2:-}"
  cat > "$base-csr.conf" <<CONF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
O = Ambient POC
CN = ${name} Intermediate CA ${suffix}
[v3_req]
subjectAltName = URI:spiffe://cluster.local/ns/istio-system/sa/citadel
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
CONF
  openssl genrsa -out "$base-ca.key" 4096 2>/dev/null
  openssl req -new -key "$base-ca.key" -config "$base-csr.conf" -out "$base-ca.csr" 2>/dev/null
  openssl x509 -req -days 730 -in "$base-ca.csr" -CA "$CERTS/root-ca.crt" -CAkey "$CERTS/root-ca.key" \
    -CAcreateserial -extfile "$base-csr.conf" -extensions v3_req -out "$base-ca.crt" 2>/dev/null
  cat "$base-ca.crt" "$CERTS/root-ca.crt" > "$base-chain.crt"
}
make_intermediate "$A" "-v2"
NEW_ISSUER_SERIAL="$(openssl x509 -noout -serial -in "$CERTS/${A}-v2-ca.crt" | cut -d= -f2)"
ok "new intermediate serial: $NEW_ISSUER_SERIAL"

step "[$A] replace cacerts; istiod reloads without a restart"
kubectl --context "$A" -n istio-system create secret generic cacerts \
  --from-file=ca-cert.pem="$CERTS/${A}-v2-ca.crt" \
  --from-file=ca-key.pem="$CERTS/${A}-v2-ca.key" \
  --from-file=root-cert.pem="$CERTS/root-ca.crt" \
  --from-file=cert-chain.pem="$CERTS/${A}-v2-chain.crt" \
  --dry-run=client -o yaml | kubectl --context "$A" apply -f - >/dev/null
for _ in $(seq 1 30); do
  kubectl --context "$A" -n istio-system logs deploy/istiod --since=2m 2>/dev/null | grep -i "reload" >/dev/null && break; sleep 5
done
kubectl --context "$A" -n istio-system logs deploy/istiod --since=3m | grep -i "reload\|x509" | tail -3 | sed 's/^/  istiod: /'

step "[$A] wait for catalog's leaf to be re-issued by the new intermediate (ztunnel renews at half life, ≤ 15 min)"
for i in $(seq 1 100); do
  CUR="$("$ISTIOCTL" --context "$A" ztunnel-config certificate "$(kubectl --context "$A" -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].metadata.name}').istio-system" -o json \
          | python3 -c "import json,sys,base64
for c in json.load(sys.stdin):
    if 'sa/catalog' in c.get('identity',''):
        print(base64.b64decode(c['certChain'][1]['pem']).decode()); break" | openssl x509 -noout -serial | cut -d= -f2)"
  if [[ "$CUR" == "$NEW_ISSUER_SERIAL" ]]; then ok "leaf now chains to the NEW intermediate ($CUR) after ~$((i*10))s"; break; fi
  [[ $((i % 6)) -eq 0 ]] && log "still issued by $CUR ... ($((i*10))s)"
  sleep 10
done
leaf_of "$A" "sa/catalog" | show_cert

step "Did anything drop? frontend errors in the last window"
AFTER="$(kubectl --context "$A" -n "$APP_NS" logs deploy/frontend --since=20m | grep -c UNREACHABLE || true)"
log "UNREACHABLE lines before: ${BEFORE:-0}   during rotation: ${AFTER:-0}"
step "Cross-cluster still fine (shared root unchanged): $B frontend -> catalog.shop.mesh.internal"
kubectl --context "$B" -n "$APP_NS" exec deploy/frontend -- curl -s -m5 http://catalog.shop.mesh.internal:8080/; echo
"$ISTIOCTL" multicluster check --contexts "$A,$B" 2>/dev/null | grep -i "certificate" || true

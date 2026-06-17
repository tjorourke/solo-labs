#!/usr/bin/env bash
# 04-routing.sh — wire the edge gateway to the app clusters:
#   1. discover each app cluster's kind node IP
#   2. render + apply the out-of-cluster Backends (node IP : NodePort)
#   3. generate an RS256 keypair + inline JWKS, render + apply the JWT policy
#   4. apply the versioned HTTPRoute
# Rendered (secret-bearing) files land in ./.gen/ which is gitignored.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

GEN="$LAB_ROOT/.gen"
mkdir -p "$GEN"

require openssl

# ── 1. discover app node IPs ────────────────────────────────────────────────
step "Discovering app cluster node addresses"
LATEST_IP="$(kind_node_ip "$APP_LATEST_CLUSTER")"; [[ -n "$LATEST_IP" ]] || die "could not find node IP for $APP_LATEST_CLUSTER"
V2_IP="$(kind_node_ip "$APP_V2_CLUSTER")";          [[ -n "$V2_IP" ]]     || die "could not find node IP for $APP_V2_CLUSTER"
ok "app-latest → ${LATEST_IP}:${APP_NODEPORT}"
ok "app-v2     → ${V2_IP}:${APP_NODEPORT}"

# ── 2. Backends ─────────────────────────────────────────────────────────────
step "Rendering + applying out-of-cluster Backends"
sed -e "s/__APP_LATEST_HOST__/${LATEST_IP}/g" \
    -e "s/__APP_LATEST_PORT__/${APP_NODEPORT}/g" \
    -e "s/__APP_V2_HOST__/${V2_IP}/g" \
    -e "s/__APP_V2_PORT__/${APP_NODEPORT}/g" \
    "$LAB_ROOT/yaml/edge/backends.yaml" > "$GEN/backends.yaml"
kctx "$EDGE_CTX" apply -f "$GEN/backends.yaml" >/dev/null
ok "Backends applied"

# ── 3. RS256 keypair + inline JWKS ──────────────────────────────────────────
KEY="$GEN/jwt-private.pem"
KID="versioned-routing-key"
if [[ ! -f "$KEY" ]]; then
  log "generating RS256 keypair → .gen/jwt-private.pem"
  openssl genrsa -out "$KEY" 2048 2>/dev/null
fi
# JWK n = base64url(raw modulus bytes); e = AQAB (65537).
MOD_HEX="$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')"
N_B64URL="$(printf '%s' "$MOD_HEX" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
JWKS_JSON="{\"keys\":[{\"kty\":\"RSA\",\"use\":\"sig\",\"alg\":\"RS256\",\"kid\":\"${KID}\",\"n\":\"${N_B64URL}\",\"e\":\"AQAB\"}]}"
echo "$JWKS_JSON" > "$GEN/jwks.json"
echo "$KID"       > "$GEN/kid.txt"

step "Rendering + applying the JWT version policy (inline JWKS)"
# JWKS_JSON is a single compact line, so the 16-space block-scalar indent in the
# template is preserved by the placeholder's own indentation.
sed "s|__JWKS_JSON__|${JWKS_JSON}|g" "$LAB_ROOT/yaml/edge/jwt-policy.yaml" > "$GEN/jwt-policy.yaml"
kctx "$EDGE_CTX" apply -f "$GEN/jwt-policy.yaml" >/dev/null
ok "EnterpriseKgatewayTrafficPolicy applied"

# ── 4. HTTPRoute ────────────────────────────────────────────────────────────
step "Applying the versioned HTTPRoute"
kctx "$EDGE_CTX" apply -f "$LAB_ROOT/yaml/edge/httproute.yaml" >/dev/null
ok "HTTPRoute applied"

step "Routing wired"
kctx "$EDGE_CTX" -n "$GW_NS" get backend,httproute,enterprisekgatewaytrafficpolicy 2>/dev/null | sed 's/^/  /' >&2 || true
echo "  Next: ./scripts/demo.sh" >&2

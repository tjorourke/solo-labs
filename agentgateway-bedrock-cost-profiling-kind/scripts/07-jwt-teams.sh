#!/usr/bin/env bash
# 07-jwt-teams.sh — Pattern A: identity selects the team's backend.
#   * RS256 key + inline-JWKS jwtAuthentication (Strict) on the gateway
#   * a PreRouting transformation projects the token's `team` claim into x-team
#     (overwriting any client value) so routing is driven by the signed claim
#   * one bedrock backend PER team, model pinned to that team's profile ARN
#   * one HTTPRoute per team, matched on x-team
# The client holds only its JWT (and asserts x-team); the ARN stays in the gateway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"
require openssl; require xxd
require_aws
[[ -f "$RESULTS_DIR/profiles.env" ]] || die "run ./scripts/03-aws-profiles.sh first"
source "$RESULTS_DIR/profiles.env"
GEN="$LAB_ROOT/.gen"; mkdir -p "$GEN"

step "Namespace + AWS creds Secret"
kctx create ns "$NS" --dry-run=client -o yaml | kctx apply -f - >/dev/null
CREDS_JSON="$(aws configure export-credentials --format process)"
AK="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
SK="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
ST="$(echo "$CREDS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("SessionToken",""))')"
ST_ARG=(); [[ -n "$ST" ]] && ST_ARG=(--from-literal=sessionToken="$ST")
kctx -n "$NS" create secret generic "$SECRET" \
  --from-literal=accessKey="$AK" --from-literal=secretKey="$SK" "${ST_ARG[@]}" \
  --dry-run=client -o yaml | kctx apply -f - >/dev/null
ok "Secret applied"

step "Generating the RS256 signing key + JWKS (kid=$JWT_KID)"
KEY="$GEN/jwt-private.pem"
[[ -f "$KEY" ]] || openssl genrsa -out "$KEY" 2048 2>/dev/null
printf '%s' "$JWT_KID" > "$GEN/kid.txt"
MOD_HEX="$(openssl rsa -in "$KEY" -noout -modulus | sed 's/^Modulus=//')"
N_B64URL="$(printf '%s' "$MOD_HEX" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
JWKS_JSON="{\"keys\":[{\"kty\":\"RSA\",\"use\":\"sig\",\"alg\":\"RS256\",\"kid\":\"${JWT_KID}\",\"n\":\"${N_B64URL}\",\"e\":\"AQAB\"}]}"
ok "JWKS derived"

step "Applying the JWT + PreRouting claim-to-header policy"
export GW_NS JWT_ISSUER JWT_AUDIENCE
JWKS_INDENTED="$(printf '%s' "$JWKS_JSON" | sed 's/^/              /')"
envsubst < "$LAB_ROOT/yaml/jwt-policy.yaml.tmpl" \
  | awk -v repl="$JWKS_INDENTED" '/^[[:space:]]*__JWKS_JSON__[[:space:]]*$/{print repl; next} {print}' \
  | kctx apply -f - >/dev/null
ok "policy 'bedrock-team-auth' applied (JWT Strict + PreRouting team→x-team)"

step "Per-team backends (model pinned) + routes (matched on x-team)"
for team in $TEAMS; do
  var="TEAM_$(echo "$team" | tr 'a-z-' 'A-Z_')_ARN"; arn="${!var}"
  [[ -z "$arn" || "$arn" == "None" ]] && { warn "no ARN for $team — skip"; continue; }
  cat <<EOF | kctx apply -f - >/dev/null
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: bedrock-${team}
  namespace: ${NS}
spec:
  ai:
    provider:
      bedrock:
        region: ${REGION}
        model: ${arn}
  policies:
    auth:
      aws:
        secretRef:
          name: ${SECRET}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bedrock-${team}
  namespace: ${NS}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${GW_NS}
  rules:
    - matches:
        - headers:
            - name: x-team
              value: ${team}
      backendRefs:
        - name: bedrock-${team}
          namespace: ${NS}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF
  ok "team $team → backend bedrock-${team} (model pinned)"
done

step "Restarting the proxy to load credentials"
kctx -n "$GW_NS" rollout restart deploy/agentgateway-proxy >/dev/null 2>&1 || true
kctx -n "$GW_NS" rollout status deploy/agentgateway-proxy --timeout=120s >/dev/null 2>&1 || true
ok "ready — mint a token:  TOKEN=\$(./scripts/mint-token.sh finance)"

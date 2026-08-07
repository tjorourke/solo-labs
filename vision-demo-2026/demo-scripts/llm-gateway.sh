#!/usr/bin/env bash
# llm-gateway.sh — stand up the Part 7 (AI gateway) platform on mesh1, on top of
# the base ./demo-scripts/setup.sh standup:
#
#   - ai-models ns: two local OpenAI-compatible model servers (built from
#     demo-scripts/llm-gateway-mock/) named azure-openai and bedrock — they play
#     Azure OpenAI and AWS Bedrock in the notebook, so the routing/failover/
#     budget demos need no cloud accounts and cost nothing. The notebook
#     presents them as the real providers; keep that in mind when presenting
#     (only the Anthropic backend leaves the cluster).
#   - anthropic secret: the one live provider (premium-reasoning), from
#     ANTHROPIC_API_KEY in $SECRETS_FILE
#   - mcp-servers ns: the MCP everything-server, deployed but NOT onboarded
#     (demo §8 onboards it with a label)
#   - ai-gateway Gateway (enterprise-agentgateway class) + model cost catalog
#     (EnterpriseAgentgatewayParameters) + tracing to the Cost Management
#     collector in solo-cost
#   - demo IdP: an RS256 keypair in demo-scripts/.jwt/ for minting persona
#     JWTs (alice/bob/carol) — stands in for a corporate IdP
#
#   SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./demo-scripts/llm-gateway.sh
#
# Idempotent — re-run freely. Remove with:  ./demo-scripts/llm-gateway.sh teardown
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-kind-mesh1}"
GW_NS=agentgateway-system
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a

# The model servers run a small local OpenAI-compatible mock (keyword-aware
# answers + real usage counts, so token limits, budgets and cost all behave).
# Built from demo-scripts/llm-gateway-mock/ into the suite's local registry.
MOCK_IMAGE="localhost:5001/llm-gateway-mock:latest"

if [ "${1:-}" = "teardown" ]; then
  kubectl --context "$CTX" delete ns ai-models mcp-servers --ignore-not-found
  kubectl --context "$CTX" -n "$GW_NS" delete gateway ai-gateway --ignore-not-found
  kubectl --context "$CTX" -n "$GW_NS" delete enterpriseagentgatewayparameters ai-gateway-params --ignore-not-found
  kubectl --context "$CTX" -n "$GW_NS" delete cm model-costs --ignore-not-found
  kubectl --context "$CTX" -n "$GW_NS" delete secret anthropic-secret --ignore-not-found
  kubectl --context "$CTX" -n "$GW_NS" delete enterpriseagentgatewaypolicy ai-gateway-tracing --ignore-not-found
  echo "✔ ai-gateway platform removed (demo resources: run the notebook Reset cell first)"
  exit 0
fi

: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY (or point SECRETS_FILE at a file that does) first}"

# ── 1. demo IdP keypair (idempotent) ──────────────────────────────────────────
JWT_DIR="$SCRIPT_DIR/.jwt"
if [ ! -f "$JWT_DIR/private.pem" ]; then
  mkdir -p "$JWT_DIR"
  openssl genrsa -out "$JWT_DIR/private.pem" 2048 2>/dev/null
  openssl rsa -in "$JWT_DIR/private.pem" -pubout -out "$JWT_DIR/public.pem" 2>/dev/null
  python3 - "$JWT_DIR" <<'PY'
import base64, json, sys
from cryptography.hazmat.primitives import serialization
d = sys.argv[1]
pub = serialization.load_pem_public_key(open(f"{d}/public.pem","rb").read())
n = pub.public_numbers()
b64 = lambda i, l: base64.urlsafe_b64encode(i.to_bytes(l, "big")).rstrip(b"=").decode()
jwks = {"keys": [{"kty":"RSA","use":"sig","alg":"RS256","kid":"demo-idp",
                  "n": b64(n.n, 256), "e": b64(n.e, 3)}]}
json.dump(jwks, open(f"{d}/jwks.json","w"), indent=1)
PY
  echo "→ demo IdP keypair minted in demo-scripts/.jwt/"
else
  echo "→ demo IdP keypair already present"
fi

# ── 2. model servers (ai-models ns) ───────────────────────────────────────────
echo "→ building + deploying the model servers (×2) ..."
if ! docker image inspect "$MOCK_IMAGE" >/dev/null 2>&1 || [ "${REBUILD_MOCK:-}" = "true" ]; then
  docker build -q -t "$MOCK_IMAGE" "$SCRIPT_DIR/llm-gateway-mock" >/dev/null
fi
docker push -q "$MOCK_IMAGE" >/dev/null
kubectl --context "$CTX" create ns ai-models --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
for entry in "azure-openai gpt-5-nano" "bedrock claude-haiku-4-5"; do
  name=${entry% *}; model=${entry#* }
  kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ai-models
  labels: { app: ${name} }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${name} } }
  template:
    metadata: { labels: { app: ${name} } }
    spec:
      containers:
        - name: model
          image: ${MOCK_IMAGE}
          imagePullPolicy: Always
          env:
            - { name: MODEL, value: "${model}" }
          ports: [{ containerPort: 8000, name: http }]
          readinessProbe: { httpGet: { path: /health, port: http }, periodSeconds: 5 }
          resources:
            requests: { cpu: 25m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata: { name: ${name}, namespace: ai-models }
spec:
  selector: { app: ${name} }
  ports: [{ port: 8000, targetPort: 8000, name: http }]
EOF
done

# ── 3. MCP everything-server (mcp-servers ns, NOT onboarded yet) ──────────────
echo "→ deploying MCP everything-server (not onboarded — §8 does that) ..."
kubectl --context "$CTX" create ns mcp-servers --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
kubectl --context "$CTX" apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: server-everything
  namespace: mcp-servers
  labels: { app: server-everything }
spec:
  replicas: 1
  selector: { matchLabels: { app: server-everything } }
  template:
    metadata: { labels: { app: server-everything } }
    spec:
      containers:
        - name: server
          image: localhost:5001/everything-server:latest
          ports: [{ containerPort: 3000, name: http }]
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 512Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: server-everything
  namespace: mcp-servers
spec:
  selector: { app: server-everything }
  ports:
    - port: 3000
      targetPort: 3000
      name: http
      appProtocol: kgateway.dev/mcp
EOF

# ── 4. anthropic secret (the one real provider) ───────────────────────────────
kubectl --context "$CTX" -n "$GW_NS" create secret generic anthropic-secret \
  --from-literal=Authorization="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
echo "→ anthropic secret applied"

# ── 5. model cost catalog + gateway + tracing ─────────────────────────────────
echo "→ ai-gateway Gateway + cost catalog + tracing ..."
kubectl --context "$CTX" apply -f - >/dev/null <<'EOF'
# USD per 1M tokens. The gateway ships a built-in catalog for real provider
# models; the sim models need these custom entries to be priced.
apiVersion: v1
kind: ConfigMap
metadata:
  name: model-costs
  namespace: agentgateway-system
data:
  catalog.json: |
    {
      "providers": {
        "openai": {
          "models": {
            "gpt-5-nano":       { "rates": { "input": "0.05", "output": "0.40" } },
            "claude-haiku-4-5": { "rates": { "input": "1",    "output": "5"    } }
          }
        },
        "anthropic": {
          "models": {
            "claude-sonnet-4-5": { "rates": { "input": "3", "output": "15" } },
            "claude-opus-5":     { "rates": { "input": "5", "output": "25" } }
          }
        }
      }
    }
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: ai-gateway-params
  namespace: agentgateway-system
spec:
  modelCatalog:
    sources:
      - configMap:
          name: model-costs
          key: catalog.json
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-gateway
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: ai-gateway-params
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
---
# Send traces (with per-request cost + identity attributes) to the Cost
# Management collector, so demo traffic lands in the Solo UI dashboards.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: ai-gateway-tracing
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
  frontend:
    tracing:
      backendRef:
        name: solo-enterprise-telemetry-collector
        namespace: solo-cost
        port: 4317
      protocol: GRPC
      randomSampling: "true"
EOF

# ── 6. wait for it all ────────────────────────────────────────────────────────
for d in azure-openai bedrock; do
  kubectl --context "$CTX" -n ai-models rollout status deploy/$d --timeout=180s >/dev/null
done
kubectl --context "$CTX" -n mcp-servers rollout status deploy/server-everything --timeout=120s >/dev/null
kubectl --context "$CTX" -n "$GW_NS" wait gateway/ai-gateway --for=condition=Programmed --timeout=120s >/dev/null
GW_IP=$(kubectl --context "$CTX" -n "$GW_NS" get gateway ai-gateway -o jsonpath='{.status.addresses[0].value}')
echo "✔ AI gateway platform up.  GATEWAY=$GW_IP"
echo "  open demo-7-llm-gateway.ipynb → run its Connect cell"

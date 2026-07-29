#!/usr/bin/env bash
# ai-gateway.sh — stand up the Part 7 (AI gateway) platform on mesh1, on top of
# the base ./demo-scripts/setup.sh standup:
#
#   - ai-models ns: three OpenAI-compatible model simulators (the llm-d
#     inference sim, no GPU) standing in for Azure OpenAI, AWS Bedrock and a
#     self-hosted vLLM — so the routing/failover/budget demos need no cloud
#     accounts and cost nothing
#   - anthropic secret: the ONE real provider (premium-reasoning), from
#     ANTHROPIC_API_KEY in $SECRETS_FILE
#   - mcp-servers ns: the MCP everything-server, deployed but NOT onboarded
#     (demo §8 onboards it with a label)
#   - ai-gateway Gateway (enterprise-agentgateway class) + model cost catalog
#     (EnterpriseAgentgatewayParameters) + tracing to the Cost Management
#     collector in solo-cost
#   - demo IdP: an RS256 keypair in demo-scripts/.jwt/ for minting persona
#     JWTs (alice/bob/carol) — stands in for a corporate IdP
#
#   SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./demo-scripts/ai-gateway.sh
#
# Idempotent — re-run freely. Remove with:  ./demo-scripts/ai-gateway.sh teardown
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-kind-mesh1}"
GW_NS=agentgateway-system
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a

SIM_IMAGE="ghcr.io/llm-d/llm-d-inference-sim:v0.10.2"

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

# ── 2. model simulators (ai-models ns) ────────────────────────────────────────
echo "→ deploying model simulators (llm-d inference sim ×3) ..."
kubectl --context "$CTX" create ns ai-models --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
for entry in "azure-sim gpt-5-nano-sim" "bedrock-sim claude-haiku-sim" "mock-llm mock-llm"; do
  name=${entry% *}; model=${entry#* }
  kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: { name: ${name}-config, namespace: ai-models }
data:
  config.yaml: |
    model: ${model}
    port: 8000
---
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
        - name: sim
          image: ${SIM_IMAGE}
          imagePullPolicy: IfNotPresent
          args: ["--config", "/etc/sim/config.yaml"]
          ports: [{ containerPort: 8000, name: http }]
          volumeMounts: [{ name: cfg, mountPath: /etc/sim }]
          readinessProbe: { httpGet: { path: /health, port: http }, periodSeconds: 5 }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: "1", memory: 512Mi }
      volumes:
        - name: cfg
          configMap: { name: ${name}-config }
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
            "gpt-5-nano-sim":   { "rates": { "input": "0.05", "output": "0.40" } },
            "claude-haiku-sim": { "rates": { "input": "1",    "output": "5"    } },
            "mock-llm":         { "rates": { "input": "0.15", "output": "0.60" } }
          }
        },
        "anthropic": {
          "models": {
            "claude-sonnet-4-5": { "rates": { "input": "3", "output": "15" } }
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
for d in azure-sim bedrock-sim mock-llm; do
  kubectl --context "$CTX" -n ai-models rollout status deploy/$d --timeout=180s >/dev/null
done
kubectl --context "$CTX" -n mcp-servers rollout status deploy/server-everything --timeout=120s >/dev/null
kubectl --context "$CTX" -n "$GW_NS" wait gateway/ai-gateway --for=condition=Programmed --timeout=120s >/dev/null
GW_IP=$(kubectl --context "$CTX" -n "$GW_NS" get gateway ai-gateway -o jsonpath='{.status.addresses[0].value}')
echo "✔ AI gateway platform up.  GATEWAY=$GW_IP"
echo "  open demo-7-ai-gateway.ipynb → run its Connect cell"

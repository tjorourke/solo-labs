#!/usr/bin/env bash
# substrate-up.sh — enable kagent Agent Substrate (gVisor) on mesh1, STANDALONE.
# If no kagent release exists it installs a minimal one (v0.5.2, anthropic provider,
# INSECURE_MODE for local dev); if Part 4's kagent is present it upgrades that in place
# (v0.4.3 -> v0.5.2). Either way it turns on the substrate subchart + a 2-replica gVisor
# WorkerPool. OPT-IN: upgrading Part 4's release bumps the kagent it shares.
#
#   ./demo-scripts/substrate-up.sh        # then demo it in demo-5-substrate.ipynb
#
set -euo pipefail
CTX="${CTX:-kind-mesh1}"; KAGENT_NS="${KAGENT_NS:-kagent}"
KENT_CRDS_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds"
KENT_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise"
KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.5.2}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a
LIC="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-${SOLO_ISTIO_LICENSE_KEY:-}}}"
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY (SECRETS_FILE) first}"
: "${LIC:?set a Solo license (KAGENT_ENT_LICENSE_KEY / SOLO_LICENSE_KEY) first}"

docker manifest inspect ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.9 >/dev/null 2>&1 \
  && echo "ateom-gvisor image reachable" \
  || echo "WARNING: pre-flight the ateom-gvisor arch/manifest (arm64 on Apple Silicon)"

SUBSTRATE_FLAGS=(
  --set substrate.enabled=true
  --set substrate.redis.clusterAddress=kagent-valkey-cluster.kagent.svc:6379
  --set substrateWorkerPool.create=true
  --set substrateWorkerPool.ateomImage=ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.9
  --set substrateWorkerPool.replicas=2
  --set substrateWorkerPool.sandboxClass=gvisor
  --set controller.substrate.enabled=true
  --set controller.substrate.ateApiEndpoint=dns:///kagent-api.kagent.svc:443
  --set controller.substrate.ateApiInsecure=true
  --set controller.substrate.atenetRouterURL=http://kagent-atenet-router.kagent.svc:80
  --set controller.substrate.ateApiServer.namespace="$KAGENT_NS"
  --set controller.substrate.ateApiServer.serviceAccount=kagent-ate-api-server
)

kubectl --context "$CTX" create namespace "$KAGENT_NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
echo "→ kagent CRDs ${KAGENT_ENT_VERSION} (adds SandboxAgent + ate.dev WorkerPool/ActorTemplate) ..."
helm --kube-context "$CTX" upgrade -i kagent-crds "$KENT_CRDS_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
  --set substrate.enabled=true --wait --timeout 5m

if helm --kube-context "$CTX" -n "$KAGENT_NS" status kagent >/dev/null 2>&1; then
  echo "→ Part 4 kagent present — upgrading it to ${KAGENT_ENT_VERSION} with substrate on (~minutes) ..."
  helm --kube-context "$CTX" upgrade kagent "$KENT_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
    --reuse-values "${SUBSTRATE_FLAGS[@]}" --wait --timeout 12m
else
  echo "→ no kagent present — installing a minimal standalone kagent ${KAGENT_ENT_VERSION} with substrate (~minutes) ..."
  helm --kube-context "$CTX" upgrade -i kagent "$KENT_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
    --set global.licensing.licenseKey="$LIC" \
    --set providers.default=anthropic \
    --set providers.anthropic.apiKey="$ANTHROPIC_API_KEY" \
    --set kagent-tools.enabled=true --set ui.enabled=false \
    --set otel.tracing.enabled=false --set otel.logging.enabled=false \
    "${SUBSTRATE_FLAGS[@]}" --wait --timeout 12m
fi
kubectl --context "$CTX" -n "$KAGENT_NS" scale deploy/kagent-controller --replicas=1 2>/dev/null || true
kubectl --context "$CTX" -n "$KAGENT_NS" set env deploy/kagent-controller INSECURE_MODE=true   # local dev only

echo "→ waiting for the substrate control plane + WorkerPool ..."
kubectl --context "$CTX" -n "$KAGENT_NS" rollout status deploy/kagent-ate-api-server-deployment --timeout=300s
kubectl --context "$CTX" -n "$KAGENT_NS" rollout status ds/kagent-atelet --timeout=300s
kubectl --context "$CTX" -n "$KAGENT_NS" wait workerpool/kagent-default --for=jsonpath='{.status.replicas}'=2 --timeout=300s
kubectl --context "$CTX" -n "$KAGENT_NS" rollout restart deploy/kagent-ate-controller   # clears accrued reconcile backoff
kubectl --context "$CTX" -n "$KAGENT_NS" rollout status deploy/kagent-ate-controller --timeout=120s
echo "✔ Agent Substrate enabled. Demo it in demo-5-substrate.ipynb."

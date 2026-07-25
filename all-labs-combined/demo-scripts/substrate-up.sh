#!/usr/bin/env bash
# substrate-up.sh — enable kagent Agent Substrate (gVisor) on mesh1: bump kagent to
# v0.5.2, turn on the substrate subchart + a 2-replica gVisor WorkerPool, and wait for
# the control plane. This BUMPS the shared kagent release (Part 4's AgentRegistry runs
# v0.4.3), so it is OPT-IN: setup.sh runs it only when ENABLE_SUBSTRATE=true. Run it
# directly to add substrate to a running cluster, then demo it in demo-5-substrate.ipynb:
#
#   ./demo-scripts/substrate-up.sh
#
set -euo pipefail
CTX="${CTX:-kind-mesh1}"; KAGENT_NS="${KAGENT_NS:-kagent}"
KENT_CRDS_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds"
KENT_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise"
KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.5.2}"

docker manifest inspect ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.9 >/dev/null 2>&1 \
  && echo "ateom-gvisor image reachable" \
  || echo "WARNING: pre-flight the ateom-gvisor arch/manifest (arm64 on Apple Silicon)"

echo "→ bumping kagent to ${KAGENT_ENT_VERSION} with substrate on (~several minutes) ..."
helm --kube-context "$CTX" upgrade -i kagent-crds "$KENT_CRDS_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
  --set substrate.enabled=true --wait --timeout 5m
helm --kube-context "$CTX" upgrade -i kagent "$KENT_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" --reuse-values \
  --set substrate.enabled=true \
  --set substrate.redis.clusterAddress=kagent-valkey-cluster.kagent.svc:6379 \
  --set substrateWorkerPool.create=true \
  --set substrateWorkerPool.ateomImage=ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.9 \
  --set substrateWorkerPool.replicas=2 \
  --set substrateWorkerPool.sandboxClass=gvisor \
  --set controller.substrate.enabled=true \
  --set controller.substrate.ateApiEndpoint=dns:///kagent-api.kagent.svc:443 \
  --set controller.substrate.ateApiInsecure=true \
  --set controller.substrate.atenetRouterURL=http://kagent-atenet-router.kagent.svc:80 \
  --set controller.substrate.ateApiServer.namespace="$KAGENT_NS" \
  --set controller.substrate.ateApiServer.serviceAccount=kagent-ate-api-server \
  --wait --timeout 10m
kubectl --context "$CTX" -n "$KAGENT_NS" scale deploy/kagent-controller --replicas=1 2>/dev/null || true
kubectl --context "$CTX" -n "$KAGENT_NS" set env deploy/kagent-controller INSECURE_MODE=true   # local dev only

echo "→ waiting for the substrate control plane + WorkerPool ..."
kubectl --context "$CTX" -n "$KAGENT_NS" rollout status deploy/kagent-ate-api-server-deployment --timeout=300s
kubectl --context "$CTX" -n "$KAGENT_NS" rollout status ds/kagent-atelet --timeout=300s
kubectl --context "$CTX" -n "$KAGENT_NS" wait workerpool/kagent-default --for=jsonpath='{.status.replicas}'=2 --timeout=300s
kubectl --context "$CTX" -n "$KAGENT_NS" rollout restart deploy/kagent-ate-controller   # clears accrued reconcile backoff
kubectl --context "$CTX" -n "$KAGENT_NS" rollout status deploy/kagent-ate-controller --timeout=120s
echo "✔ Agent Substrate enabled. Demo it in demo-5-substrate.ipynb."

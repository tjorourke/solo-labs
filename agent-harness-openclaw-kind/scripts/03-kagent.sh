#!/usr/bin/env bash
# 03-kagent.sh — install kagent with the Substrate integration and a two-worker gVisor WorkerPool.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_secrets

step "kagent ${KAGENT_VERSION} CRDs"
helm --kube-context "$CTX" upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version "$KAGENT_VERSION" --namespace "$NS" --create-namespace --wait >/dev/null

step "provider key Secret ${NS}/${MODEL_SECRET} (from the environment, never from Helm values)"
kc -n "$NS" create secret generic "$MODEL_SECRET" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

step "kagent ${KAGENT_VERSION} with controller.substrate.enabled=true"
helm_install_with_progress kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent "$NS" \
  --version "$KAGENT_VERSION" -f "$YAML/10-kagent-values.yaml" \
  --set "providers.anthropic.model=${MODEL_NAME}" \
  --set "substrateWorkerPool.ateomImage=${ATEOM_IMAGE}" \
  --wait --timeout 15m
wait_deploy "$NS" kagent-controller 600s
kc get crd agentharnesses.kagent.dev >/dev/null || die "AgentHarness CRD missing"

step "WorkerPool ${WORKER_POOL}: two gVisor workers registered with the ate-api-server"
kc -n "$NS" wait "workerpool/${WORKER_POOL}" --for=jsonpath='{.status.replicas}'=2 --timeout=300s >/dev/null
kc -n "$NS" wait pod -l "ate.dev/worker-pool=${WORKER_POOL}" --for=condition=Ready --timeout=300s >/dev/null
# The WorkerPool reporting pods Ready is a Kubernetes signal. The ate-api-server keeps its
# own worker store; until it lists the workers no actor can be placed.
registered=0
for _ in $(seq 1 60); do
  registered=$(substrate_status | python3 -c 'import sys,json; d=json.load(sys.stdin).get("data",{}); print(len(d.get("workers",[])))' 2>/dev/null || echo 0)
  [[ "$registered" -ge 2 ]] && break
  sleep 5
done
[[ "$registered" -ge 2 ]] || die "ate-api-server registered ${registered} workers; expected 2"
kc -n "$NS" get workerpools.ate.dev
kc -n "$NS" get pods
ok "kagent controller reports substrate enabled with ${registered} workers"

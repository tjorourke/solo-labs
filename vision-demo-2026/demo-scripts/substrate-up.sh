#!/usr/bin/env bash
# substrate-up.sh — enable kagent Agent Substrate (gVisor) on a cluster.
# If no kagent release exists it installs a minimal one (anthropic provider,
# INSECURE_MODE for local dev); if one is already there (Part 4's, say) it upgrades that
# release in place. Either way it turns on the substrate subchart + a 2-replica gVisor
# WorkerPool.
#
#   ./demo-scripts/substrate-up.sh                 # the Part 5 cluster (kind-substrate)
#   CTX=kind-mesh1 ./demo-scripts/substrate-up.sh  # add substrate to Part 4's cluster
#
# Part 4 and Part 5 now run the SAME kagent version, so the version clash that once
# forced them onto separate clusters is gone: mesh1 can carry substrate too, which is
# what an AgentHarness needs (its spec.substrate is required).
#
set -euo pipefail
# NOT ${CTX:-...}. connect.sh and env.sh both export CTX=kind-mesh1, so running this in a
# shell that had sourced either silently upgraded Part 4's kagent instead of the Part 5
# cluster — and a cancelled upgrade there migrates the database forward, which the older
# controller then cannot start against. Use a name nothing else exports.
CTX="${SUBSTRATE_CTX:-kind-substrate}"; KAGENT_NS="${KAGENT_NS:-kagent}"
# Say out loud which cluster is about to be changed, so a wrong target is obvious before
# any helm work starts rather than after.
echo "→ target cluster: $CTX   (override with SUBSTRATE_CTX=<context>)"
KENT_CRDS_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds"
KENT_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise"
KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.5.6}"
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

KSTATUS="$(helm --kube-context "$CTX" -n "$KAGENT_NS" status kagent -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
if [ "$KSTATUS" = "deployed" ]; then
  echo "→ Part 4 kagent present — upgrading it to ${KAGENT_ENT_VERSION} with substrate on (~minutes) ..."
  # --reset-then-reuse-values, NOT --reuse-values: plain reuse carries the previous
  # release's values over verbatim and never picks up defaults a newer chart added, so
  # upgrading across versions dies rendering a template that reads one of them
  # (0.5.2 -> 0.5.6 fails on controller.serviceAccount.annotations being nil).
  helm --kube-context "$CTX" upgrade kagent "$KENT_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
    --reset-then-reuse-values "${SUBSTRATE_FLAGS[@]}" --wait --timeout 12m
else
  [ -n "$KSTATUS" ] && { echo "→ clearing a non-deployed kagent release (status: $KSTATUS) ..."; helm --kube-context "$CTX" -n "$KAGENT_NS" uninstall kagent >/dev/null 2>&1 || true; }
  echo "→ installing a minimal standalone kagent ${KAGENT_ENT_VERSION} with substrate (~minutes) ..."
  helm --kube-context "$CTX" upgrade -i kagent "$KENT_CHART" -n "$KAGENT_NS" --version "$KAGENT_ENT_VERSION" \
    --set global.licensing.licenseKey="$LIC" \
    --set providers.default=anthropic \
    --set providers.anthropic.apiKey="$ANTHROPIC_API_KEY" \
    --set kagent-tools.enabled=true --set ui.enabled=false \
    --set otel.tracing.enabled=false --set otel.logging.enabled=false \
    --set-json 'controller.env=[{"name":"INSECURE_MODE","value":"true"}]' \
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
# The WorkerPool reporting its pods Ready is a Kubernetes-level signal only. The
# ate-api-server keeps its OWN worker store and populates it some time later; until it
# has, no actor can be placed ("no free workers available"). Because ate-controller
# backs off exponentially, the FIRST SandboxAgent a demo creates can then sit unready
# for minutes and look like a broken product. So prove an actor can actually be placed
# before claiming substrate is enabled, retrying to reset that backoff.
echo "→ verifying substrate can place an actor ..."
CANARY="$(mktemp)"
cat > "$CANARY" <<'YAML'
apiVersion: kagent.dev/v1alpha2
kind: SandboxAgent
metadata: { name: substrate-canary, namespace: kagent }
spec:
  type: Declarative
  description: setup canary, removed as soon as it is Ready
  declarative: { runtime: go, modelConfig: default-model-config, systemMessage: "canary" }
  substrate: { workerPoolRef: { name: kagent-default } }
YAML
CANARY_OK=false
for attempt in $(seq 1 10); do
  kubectl --context "$CTX" apply -f "$CANARY" >/dev/null 2>&1 || true
  if kubectl --context "$CTX" -n "$KAGENT_NS" wait sandboxagent/substrate-canary \
       --for=condition=Ready --timeout=45s >/dev/null 2>&1; then
    CANARY_OK=true
    echo "  ✓ actor placed (attempt $attempt) — substrate is genuinely ready"
    break
  fi
  MSG="$(kubectl --context "$CTX" -n "$KAGENT_NS" get sandboxagent substrate-canary \
           -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"
  echo "  attempt $attempt: ${MSG:-no status yet} — retrying"
  kubectl --context "$CTX" -n "$KAGENT_NS" delete sandboxagent substrate-canary --ignore-not-found >/dev/null 2>&1 || true
done
kubectl --context "$CTX" -n "$KAGENT_NS" delete sandboxagent substrate-canary --ignore-not-found >/dev/null 2>&1 || true
rm -f "$CANARY"
if [ "$CANARY_OK" != true ]; then
  echo "✗ substrate installed but it cannot place an actor. Look at:" >&2
  echo "    kubectl --context $CTX -n $KAGENT_NS logs deploy/kagent-ate-controller --tail=20" >&2
  echo "    kubectl --context $CTX -n $KAGENT_NS logs deploy/kagent-ate-api-server-deployment | grep -i worker" >&2
  exit 1
fi

echo "✔ Agent Substrate enabled. Demo it in demo-5-substrate.ipynb."

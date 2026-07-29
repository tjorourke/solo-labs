#!/usr/bin/env bash
# cost-mgmt.sh — install the Solo Enterprise management chart + ClickHouse on mesh1
# and seed it with example LLM-spend data, so demo-1 §1.9's Cost Management UI opens
# fully populated. Idempotent (re-run upgrades in place). setup.sh calls this at
# standup; run it directly to add Cost Management to an already-running cluster:
#
#   ./demo-scripts/cost-mgmt.sh          # then ./demo-scripts/consoles.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER1="${CLUSTER1:-kind-mesh1}"
CLUSTER1_NAME="${CLUSTER1_NAME:-${CLUSTER1#kind-}}"
MGMT_VERSION="${MGMT_VERSION:-0.5.2}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a
: "${AGENTGATEWAY_LICENSE_KEY:?set AGENTGATEWAY_LICENSE_KEY (or point SECRETS_FILE at a file that does) first}"

echo "→ installing Cost Management (management chart + ClickHouse) on ${CLUSTER1_NAME} (~a few minutes) ..."
helm --kube-context "$CLUSTER1" upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  -n solo-cost --create-namespace --version "$MGMT_VERSION" \
  --set cluster="$CLUSTER1_NAME" \
  --set products.agentgateway.enabled=true \
  --set products.agentgateway.namespace=agentgateway-system \
  --set products.agentgateway.features.cost-management=true \
  --set products.agentgateway.features.cost-management-writes=true \
  --set clickhouse.persistentVolume.enabled=false \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --wait --timeout 6m
kubectl --context "$CLUSTER1" -n solo-cost rollout status statefulset/management-clickhouse-shard0 --timeout=300s
echo "→ seeding example spend into ClickHouse ..."
CTX="$CLUSTER1" NS=solo-cost CH_POD=management-clickhouse-shard0-0 TRUNCATE=true ROWS=300000 DAYS=30 \
  bash "$SCRIPT_DIR/seed-clickhouse.sh"
echo "✔ Cost Management up + seeded. Open it:  ./demo-scripts/consoles.sh  → http://localhost:8095/age/cost-management"

#!/usr/bin/env bash
# setup.sh — stand up the whole Cost Management demo on one kind cluster.
#
# Brings up: enterprise-agentgateway (control plane + custom budget dimensions),
# the Solo Enterprise management UI + bundled ClickHouse with the cost-management
# feature on, then applies the cost pipeline (virtual keys, gateway/backend/route,
# api-key + budget-enforcement policy, budgets). Seed data is a separate step
# (scripts/seed-clickhouse.sh) so you can choose how much history to backfill.
#
# Prereqs exported in your shell (or ~/code/solo/secrets/secrets-envs.sh):
#   AGENTGATEWAY_LICENSE_KEY   enterprise-agentgateway + management license
#   OPENAI_API_KEY             the upstream key the openai backend proxies to
#
#   ./scripts/setup.sh                 # bring it all up
#   TRUNCATE=true ./scripts/seed-clickhouse.sh   # then backfill a month of spend
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── config (matches the names seed-clickhouse.sh + the yaml/ manifests expect) ─
CLUSTER="${CLUSTER:-agentgateway-cost}"
CTX="kind-${CLUSTER}"
GW_NS="${GW_NS:-gloo-system}"                 # gateway + controller + policies + budgets
MGMT_NS="${MGMT_NS:-kagent}"                  # management chart (release 'management' → management-clickhouse-shard0-0)
VIRTUAL_KEY_SET="${VIRTUAL_KEY_SET:-cost-demo-virtual-keys}"

AGW_VERSION="${AGW_VERSION:-v2026.7.0}"
MGMT_VERSION="${MGMT_VERSION:-0.5.0}"
GWAPI_VERSION="${GWAPI_VERSION:-v1.4.0}"
AGW_REG="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts"
MGMT_CHART="oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management"

step() { printf '\n\033[1;36m══> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

# ── secrets ───────────────────────────────────────────────────────────────────
SECRETS="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
if [ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ] || [ -z "${OPENAI_API_KEY:-}" ]; then
  # shellcheck disable=SC1090
  [ -f "$SECRETS" ] && { set -a; . "$SECRETS"; set +a; }
fi
: "${AGENTGATEWAY_LICENSE_KEY:?set AGENTGATEWAY_LICENSE_KEY (or point SECRETS_FILE at secrets-envs.sh)}"
: "${OPENAI_API_KEY:?set OPENAI_API_KEY}"
# openai backend secret is the verbatim Authorization header — normalise to Bearer <key>.
_raw="${OPENAI_API_KEY#Bearer }"; _raw="${_raw# }"
OPENAI_AUTH="Bearer ${_raw}"

kc() { kubectl --context "$CTX" "$@"; }

# ── 1. cluster ──────────────────────────────────────────────────────────────
step "kind cluster ${CLUSTER}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  ok "cluster already exists"
else
  kind create cluster --name "$CLUSTER"
  ok "cluster created"
fi

# ── 2. Gateway API CRDs ───────────────────────────────────────────────────────
step "Gateway API experimental CRDs ${GWAPI_VERSION}"
# --server-side: the experimental CRDs carry a last-applied annotation that blows
# past the 256KB client-side apply limit ("metadata.annotations: Too long").
kc apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/experimental-install.yaml" >/dev/null
ok "Gateway API CRDs applied"

# ── 3. enterprise-agentgateway (CRDs + control plane + custom dimensions) ─────
step "Enterprise agentgateway CRDs ${AGW_VERSION}"
helm upgrade --install agentgateway-crds "${AGW_REG}/enterprise-agentgateway-crds" \
  --kube-context "$CTX" --namespace "$GW_NS" --create-namespace \
  --version "$AGW_VERSION" --wait >/dev/null
ok "CRDs installed"

step "Enterprise agentgateway control plane ${AGW_VERSION} (+ custom budget dimensions)"
helm upgrade --install enterprise-agentgateway "${AGW_REG}/enterprise-agentgateway" \
  --kube-context "$CTX" --namespace "$GW_NS" \
  --version "$AGW_VERSION" \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  -f "$LAB_ROOT/yaml/budget-dimensions.values.yaml" \
  --wait --timeout 5m >/dev/null
ok "control plane installed with costCenter / environment / project / application dimensions"

# ── 4. Solo Enterprise management chart (UI + ClickHouse + cost-management on) ─
step "Solo Enterprise management chart ${MGMT_VERSION} (release 'management' in ${MGMT_NS})"
helm upgrade --install management "$MGMT_CHART" \
  --kube-context "$CTX" --namespace "$MGMT_NS" --create-namespace \
  --version "$MGMT_VERSION" \
  --set cluster="$CLUSTER" \
  --set products.agentgateway.enabled=true \
  --set products.agentgateway.namespace="$GW_NS" \
  --set products.agentgateway.features.cost-management=true \
  --set products.agentgateway.features.cost-management-writes=true \
  --set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --set clickhouse.persistentVolume.enabled=false \
  --wait --timeout 8m >/dev/null
ok "management chart installed (Cost Management UI + ClickHouse)"
kc -n "$MGMT_NS" rollout status statefulset/management-clickhouse-shard0 --timeout=300s >/dev/null 2>&1 || true

# ── 5. virtual keys (Secret the api-key policy selects) ───────────────────────
step "Virtual keys → Secret/${VIRTUAL_KEY_SET} (from yaml/virtual-keys.csv)"
python3 - "$LAB_ROOT/yaml/virtual-keys.csv" "$VIRTUAL_KEY_SET" "$GW_NS" <<'PY' | kc apply -f - >/dev/null
import csv, json, sys
csv_path, key_set, ns = sys.argv[1], sys.argv[2], sys.argv[3]
rows = list(csv.DictReader(open(csv_path)))
print("apiVersion: v1\nkind: Secret\nmetadata:")
print(f"  name: {key_set}\n  namespace: {ns}")
print(f"  labels:\n    agentgateway.solo.io/virtual-key-set: {key_set}")
print("type: Opaque\nstringData:")
for r in rows:
    meta = {k.split('.',1)[1]: v for k, v in r.items()
            if k.startswith('metadata.') and v}
    # id + name live inside metadata; the apiKey CEL object hoists metadata
    # fields to top level, so apiKey.id / apiKey.costCenter / … resolve.
    meta["id"] = r["id"]
    meta.setdefault("name", r.get("metadata.user") or r["entry"])
    blob = {"key": r["key"], "metadata": meta}
    print(f'  {r["entry"]}: {json.dumps(json.dumps(blob))}')
PY
ok "$(wc -l < "$LAB_ROOT/yaml/virtual-keys.csv" | tr -d ' ') rows → virtual keys applied"

# ── 6. gateway + backend + route + api-key/budget policy ──────────────────────
step "Gateway + openai backend + /openai route + api-key/budget policy"
OPENAI_API_KEY="$OPENAI_AUTH" GATEWAY_NAMESPACE="$GW_NS" VIRTUAL_KEY_SET="$VIRTUAL_KEY_SET" \
  envsubst < "$LAB_ROOT/yaml/gateway-resources.yaml" | kc apply -f - >/dev/null
ok "gateway resources applied"

# ── 7. budgets (so dimensions attribute + limits enforce) ─────────────────────
step "Budgets"
kc apply -f "$LAB_ROOT/yaml/budgets.yaml" >/dev/null
ok "budgets applied"

# ── 8. wait for the data plane ────────────────────────────────────────────────
step "Waiting for the gateway to program"
kc -n "$GW_NS" rollout status deploy/agentgateway --timeout=180s >/dev/null 2>&1 || true
ok "gateway rollout complete"

cat <<EOF

══════════════════════════════════════════════════════════════════
  Cost Management demo ready on ${CTX}
══════════════════════════════════════════════════════════════════
  Backfill a month of spend:
    TRUNCATE=true ROWS=300000 DAYS=30 ./scripts/seed-clickhouse.sh

  Open the Cost Management UI (frontend is svc port 80 → pod 8090):
    kubectl --context ${CTX} -n ${MGMT_NS} port-forward svc/solo-enterprise-ui 8090:80
    open http://localhost:8090/age/cost-management

  Send a live priced request:
    kubectl --context ${CTX} -n ${GW_NS} port-forward svc/agentgateway 8080:8080 &
    curl -s localhost:8080/openai -H 'Authorization: Bearer sk-acme-prod-001' \\
      -H 'content-type: application/json' \\
      -d '{"messages":[{"role":"user","content":"hello"}]}'
EOF

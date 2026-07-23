#!/usr/bin/env bash
# 06-scale.sh — demo 3: tenant scale ramp. Deploys N tenant namespaces to BOTH
# clusters, each with one tiny global service, and measures what actually
# scales in an ambient peering setup: istiod push behaviour, ztunnel memory,
# and time-to-discovery of a new global service from the peer cluster.
#
#   ./06-scale.sh 100      # ramp to 100 tenants (default)
#   ./06-scale.sh 1000     # the full customer number — scale nodegroups first:
#                          #   eksctl scale nodegroup --cluster <name> -r <region> --name workers -N 10
#
# There is no management plane in this data path — what you are load-testing is
# istiod (per cluster) and the peering fan-out, which is the honest test.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

N="${1:-100}"
CTX1="$(ctx_of "$NAME1" "$REGION1")"; CTX2="$(ctx_of "$NAME2" "$REGION2")"
[[ -n "$CTX1" && -n "$CTX2" ]] || die "missing kube contexts"

tenant_yaml() { # tenant_yaml <i>
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-$1
  labels: { istio.io/dataplane-mode: ambient, lab: mesh-scale }
---
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: tenant-$1
  labels: { app: app, istio.io/global: "true" }
spec:
  trafficDistribution: PreferClose
  selector: { app: app }
  ports: [{ name: http, port: 8080, targetPort: 8080, appProtocol: http }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: tenant-$1
spec:
  replicas: 1
  selector: { matchLabels: { app: app } }
  template:
    metadata: { labels: { app: app } }
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:1.0
          args: ["-listen=:8080", "-text=tenant-$1"]
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 5m, memory: 8Mi }
            limits: { memory: 32Mi }
EOF
}

metrics() { # metrics <ctx> <label>
  local ctx="$1" label="$2"
  local pushes rss
  pushes="$(kubectl --context "$ctx" -n istio-system exec deploy/istiod -- \
    curl -s localhost:15014/metrics 2>/dev/null | grep -E '^pilot_xds_pushes|^pilot_proxy_convergence_time_sum|^pilot_proxy_convergence_time_count' | head -6)"
  echo "── $label istiod ──"; echo "$pushes"
  echo "── $label istiod resources ──"
  kubectl --context "$ctx" -n istio-system top pod -l app=istiod 2>/dev/null || true
  echo "── $label ztunnel resources ──"
  kubectl --context "$ctx" -n istio-system top pod -l app=ztunnel 2>/dev/null || true
}

step "Baseline metrics"
metrics "$CTX1" "$REGION1"

step "Ramping to $N tenants on BOTH clusters"
START=$(date +%s)
for i in $(seq 1 "$N"); do
  tenant_yaml "$i" | kubectl --context "$CTX1" apply -f - >/dev/null
  tenant_yaml "$i" | kubectl --context "$CTX2" apply -f - >/dev/null
  (( i % 50 == 0 )) && log "$i/$N applied ($(( $(date +%s) - START ))s)"
done
ok "$N tenants applied to both clusters in $(( $(date +%s) - START ))s"

step "Waiting for pods (sampling readiness)"
for _ in $(seq 1 60); do
  READY1="$(kubectl --context "$CTX1" get pods -A -l app=app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  READY2="$(kubectl --context "$CTX2" get pods -A -l app=app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log "running: $REGION1=$READY1/$N  $REGION2=$READY2/$N"
  [[ "$READY1" -ge "$N" && "$READY2" -ge "$N" ]] && break
  sleep 10
done

step "Time-to-discovery: new global service visible from the peer"
T0=$(date +%s%3N)
tenant_yaml "probe" | kubectl --context "$CTX1" apply -f - >/dev/null
kubectl --context "$CTX1" -n tenant-probe rollout status deploy/app --timeout=120s >/dev/null
for _ in $(seq 1 120); do
  R="$(kubectl --context "$CTX2" -n shop exec deploy/client -- \
      curl -s -m2 http://app.tenant-probe.svc.cluster.local:8080/ 2>/dev/null || true)"
  [[ "$R" == *"tenant-probe"* ]] && break
  sleep 1
done
T1=$(date +%s%3N)
ok "peer cluster served tenant-probe after $(( T1 - T0 ))ms (includes pod start)"

step "Metrics at $N tenants"
metrics "$CTX1" "$REGION1"
metrics "$CTX2" "$REGION2"

echo
ok "scale ramp to $N done. Clean up scale tenants with:"
log "  kubectl --context <ctx> delete ns -l lab=mesh-scale"

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

# Scale the nodegroups to fit N before ramping, rather than after finding out.
# The default cluster is three m5.large per region. AWS VPC CNI caps an m5.large
# at 29 pods, so three nodes leave about 64 schedulable once system pods have
# taken theirs, and a default run of 100 tenants stalls at exactly 64/100 on both
# clusters and then times out waiting for discovery. The lab already documented
# scaling as the fix for N=1000; it is needed for the default N too.
# About 22 tenant pods per node once system pods are accounted for.
NODES_NEEDED=$(( (N + 21) / 22 ))
if (( NODES_NEEDED < 3 )); then NODES_NEEDED=3; fi
# maxSize in the eksctl configs is 12. Asking for more just fails, so cap and say so.
if (( NODES_NEEDED > 12 )); then
  echo "  note: $N tenants would need ~$NODES_NEEDED nodes; capping at the nodegroup maxSize of 12"
  NODES_NEEDED=12
fi
scale_nodes_for_n() {
  local cluster="$1" region="$2"
  local have
  have="$(eksctl get nodegroup --cluster "$cluster" --region "$region" --name workers -o json 2>/dev/null \
          | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
print(d[0].get("DesiredCapacity",0) if d else 0)' 2>/dev/null || echo 0)"
  have="${have:-0}"
  if (( have < NODES_NEEDED )); then
    echo "  scaling $cluster workers ${have} -> ${NODES_NEEDED} so $N tenants can schedule"
    eksctl scale nodegroup --cluster "$cluster" --region "$region" --name workers \
      -N "$NODES_NEEDED" -M 12 >/dev/null 2>&1 || echo "  warn: could not scale $cluster workers" >&2
  fi
}
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
  labels: { app: app, solo.io/service-scope: global }
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
  # `|| true`: this is a metrics REPORT, and it must never fail the lab. Two ways
  # it can exit non-zero under set -e: grep returns 1 when a counter has not been
  # emitted yet, and `exec ... curl` returns non-zero when the istiod image has no
  # curl. Neither says anything about whether the mesh works.
  pushes="$(kubectl --context "$ctx" -n istio-system exec deploy/istiod -- \
    curl -s localhost:15014/metrics 2>/dev/null | grep -E '^pilot_xds_pushes|^pilot_proxy_convergence_time_sum|^pilot_proxy_convergence_time_count' | head -6 || true)"
  [[ -n "$pushes" ]] || pushes="  (istiod metrics unavailable: no curl in the image, or no counters yet)"
  echo "── $label istiod ──"; echo "$pushes"
  echo "── $label istiod resources ──"
  kubectl --context "$ctx" -n istio-system top pod -l app=istiod 2>/dev/null || true
  echo "── $label ztunnel resources ──"
  kubectl --context "$ctx" -n istio-system top pod -l app=ztunnel 2>/dev/null || true
}

step "Baseline metrics"
metrics "$CTX1" "$REGION1"

step "Sizing the nodegroups for $N tenants"
scale_nodes_for_n "$NAME1" "$REGION1"
scale_nodes_for_n "$NAME2" "$REGION2"

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
# The peer dials the GLOBAL hostname (<svc>.<ns>.mesh.internal), which is what
# solo.io/service-scope=global publishes across the peered mesh. The peer has no
# tenant-probe namespace of its own, so the cluster-local name means nothing
# there — only the global hostname does.
T0=$(date +%s%3N)
tenant_yaml "probe" | kubectl --context "$CTX1" apply -f - >/dev/null
kubectl --context "$CTX1" -n tenant-probe rollout status deploy/app --timeout=120s >/dev/null
discovered=""
for _ in $(seq 1 120); do
  R="$(kubectl --context "$CTX2" -n shop exec deploy/client -- \
      curl -s -m2 http://app.tenant-probe.mesh.internal:8080/ 2>/dev/null || true)"
  [[ "$R" == *"tenant-probe"* ]] && { discovered=yes; break; }
  sleep 1
done
T1=$(date +%s%3N)
# Fail loudly. Without this the loop simply runs out and the elapsed time gets
# reported as if discovery had succeeded.
[[ -n "$discovered" ]] \
  || die "peer cluster never served app.tenant-probe.mesh.internal within 120s — cross-cluster discovery of a new global service is not working"
ok "peer cluster served tenant-probe after $(( T1 - T0 ))ms (includes pod start)"

step "Metrics at $N tenants"
metrics "$CTX1" "$REGION1"
metrics "$CTX2" "$REGION2"

echo
ok "scale ramp to $N done. Clean up scale tenants with:"
log "  kubectl --context <ctx> delete ns -l lab=mesh-scale"

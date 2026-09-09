#!/usr/bin/env bash
# 03-app.sh — the demo workload: region-echo, deployed to BOTH clusters as a
# single global service.
#
# The API answers {"region": "...", "pod": "..."} so every response tells you
# which region served it. The Service carries:
#   istio.io/global: "true"                                -> published mesh-wide
#   networking.istio.io/traffic-distribution: PreferNetwork -> stay local, fail
#      over cross-region only when local endpoints are unhealthy
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CTX1="$(ctx_of "$NAME1" "$REGION1")"; CTX2="$(ctx_of "$NAME2" "$REGION2")"
[[ -n "$CTX1" && -n "$CTX2" ]] || die "missing kube contexts"

deploy() {
  local ctx="$1" region="$2"
  step "[$region] deploying region-echo (ambient namespace 'shop')"
  kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: region-echo, namespace: shop }
---
apiVersion: v1
kind: Service
metadata:
  name: region-echo
  namespace: shop
  labels:
    app: region-echo
    # Current Solo label for publishing a service across the peered mesh. It
    # creates region-echo.shop.mesh.internal from every cluster that carries the
    # same labelled Service. (The old istio.io/global label predates it.)
    solo.io/service-scope: global
    # The client below dials region-echo.shop.svc.cluster.local, the ordinary
    # in-cluster name. Takeover points that name at the global hostname, which is
    # what makes the cross-region failover in demo 04 happen with no client
    # change. Without it, requests to the cluster.local name stay local and the
    # demo would simply fail when the local endpoints go away.
    solo.io/service-takeover: "true"
spec:
  # k8s-native locality preference — istiod translates this to ztunnel's
  # Failover LB policy (Network -> Region -> Zone, healthy endpoints only).
  # (the networking.istio.io/traffic-distribution ANNOTATION is ignored on
  # this build — use the field)
  trafficDistribution: PreferClose
  selector: { app: region-echo }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      appProtocol: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: region-echo
  namespace: shop
spec:
  replicas: 2
  selector: { matchLabels: { app: region-echo } }
  template:
    metadata:
      labels: { app: region-echo }
    spec:
      serviceAccountName: region-echo
      containers:
        - name: api
          image: python:3.12-alpine
          command: ["python3","-u","-c"]
          args:
            - |
              import http.server, socketserver, json, os
              class H(http.server.BaseHTTPRequestHandler):
                  def do_GET(self):
                      b=json.dumps({"region": os.environ.get("REGION","?"),
                                    "pod": os.environ.get("POD_NAME","?")}).encode()
                      self.send_response(200)
                      self.send_header("Content-Type","application/json")
                      self.send_header("Content-Length",str(len(b)))
                      self.end_headers(); self.wfile.write(b)
                  def log_message(self,*a): pass
              socketserver.TCPServer.allow_reuse_address=True
              socketserver.ThreadingTCPServer(("0.0.0.0",8080),H).serve_forever()
          env:
            - name: REGION
              value: "${region}"
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
          ports: [{ containerPort: 8080 }]
          readinessProbe:
            tcpSocket: { port: 8080 }
            initialDelaySeconds: 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: shop
spec:
  replicas: 1
  selector: { matchLabels: { app: client } }
  template:
    metadata:
      labels: { app: client }
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.9.1
          command: ["sh","-c"]
          args:
            - |
              while true; do
                R=\$(curl -s -m3 http://region-echo.shop.svc.cluster.local:8080/ || echo '{"region":"UNREACHABLE"}')
                echo "\$(date +%H:%M:%S) -> \$R"
                sleep 2
              done
EOF
  kubectl --context "$ctx" -n shop rollout status deploy/region-echo deploy/client --timeout=180s >/dev/null
  ok "[$region] region-echo + client running"
}

deploy "$CTX1" "$REGION1"
deploy "$CTX2" "$REGION2"

step "Assert the global hostname was published in both regions"
# solo.io/service-scope=global makes istiod synthesise an autogen ServiceEntry
# for <svc>.<ns>.mesh.internal. If this is missing, the service is cluster-local
# and every failover demo below is meaningless, so fail here rather than print a
# green tick and fail confusingly three scripts later.
for pair in "$CTX1:$REGION1" "$CTX2:$REGION2"; do
  IFS=: read -r ctx region <<<"$pair"
  for _ in $(seq 1 30); do
    if kubectl --context "$ctx" -n istio-system get serviceentry -o jsonpath='{.items[*].spec.hosts[*]}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx 'region-echo.shop.mesh.internal'; then
      ok "[$region] region-echo.shop.mesh.internal published"
      break
    fi
    sleep 5
  done || true
  kubectl --context "$ctx" -n istio-system get serviceentry -o jsonpath='{.items[*].spec.hosts[*]}' 2>/dev/null \
    | tr ' ' '\n' | grep -qx 'region-echo.shop.mesh.internal' \
    || die "[$region] no ServiceEntry for region-echo.shop.mesh.internal — the global-service label did not take effect"
done

echo
step "Sanity: what does each cluster's client see?"
sleep 8
echo "[$REGION1 client]"; kubectl --context "$CTX1" -n shop logs deploy/client --tail=3
echo "[$REGION2 client]"; kubectl --context "$CTX2" -n shop logs deploy/client --tail=3

# Assert, do not eyeball. Each client must be served by its OWN region while both
# are healthy (PreferClose). A run where both clients are served by one region is
# a broken locality preference that still "passes" if nobody reads the logs.
for pair in "$CTX1:$REGION1" "$CTX2:$REGION2"; do
  IFS=: read -r ctx region <<<"$pair"
  seen="$(kubectl --context "$ctx" -n shop logs deploy/client --tail=5 2>/dev/null || true)"
  grep -q "\"region\": *\"$region\"" <<<"$seen" \
    || { echo "$seen" >&2; die "[$region] client is not being served locally — locality preference is not working"; }
  ok "[$region] served locally"
done
ok "each client served by its OWN region (PreferClose)"

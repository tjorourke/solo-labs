#!/usr/bin/env bash
# Metrics, alerting and the alert email, made real. Prometheus, Grafana and Alertmanager
# with an in-cluster Mailpit as the SMTP sink, so an alert email can be shown on screen
# with no credentials and nothing leaving the cluster.
#
#   ./scripts/observability.sh up      kube-prometheus-stack + Mailpit + the demo alert
#   ./scripts/observability.sh alert   fire the demo alert (scale the canary to zero)
#   ./scripts/observability.sh reset    clear it (scale the canary back)
#   ./scripts/observability.sh mail     read what landed in the Mailpit inbox
#   ./scripts/observability.sh urls     the Grafana / Prometheus / Alertmanager / Mailpit URLs
#   ./scripts/observability.sh status   what is running
#
# Prometheus and Grafana are OSS, correctly: there is no Solo observability product, and
# these are the standard stack. The Solo signal comes from what they scrape, the mesh,
# gateway and policy layers.
#
# The demo alert is deliberately not tied to the model: it watches a throwaway "canary"
# Deployment so the email can be shown on demand without scaling vLLM. Scale the canary to
# zero, the alert fires within a minute, Alertmanager mails Mailpit, and `mail` shows it.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=monitoring
KPS_VERSION="${KPS_VERSION:-65.5.0}"        # kube-prometheus-stack chart

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

lb_host() { kc -n agentgateway-system get svc sovereign-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null; }

case "${1:-status}" in
  up)
    echo "==> Mailpit (in-cluster SMTP sink + web UI)"
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kc apply -n "$NS" -f - >/dev/null <<'MAILPIT'
apiVersion: apps/v1
kind: Deployment
metadata: { name: mailpit, labels: { app: mailpit } }
spec:
  replicas: 1
  selector: { matchLabels: { app: mailpit } }
  template:
    metadata: { labels: { app: mailpit } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: mailpit
          image: axllent/mailpit:v1.21.0
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
          ports:
            - { name: smtp, containerPort: 1025 }
            - { name: http, containerPort: 8025 }
          readinessProbe: { httpGet: { path: /, port: 8025 }, initialDelaySeconds: 3 }
---
apiVersion: v1
kind: Service
metadata: { name: mailpit, labels: { app: mailpit } }
spec:
  selector: { app: mailpit }
  ports:
    - { name: smtp, port: 1025, targetPort: 1025 }
    - { name: http, port: 8025, targetPort: 8025 }
MAILPIT
    kc -n "$NS" rollout status deploy/mailpit --timeout=180s

    echo "==> kube-prometheus-stack $KPS_VERSION (Prometheus + Grafana + Alertmanager)"
    helm_ repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm_ repo update prometheus-community >/dev/null 2>&1 || true
    # Alertmanager mails Mailpit. Everything routes to the email receiver, including the
    # always-on Watchdog, so there is always something in the inbox to show, and the demo
    # canary alert lands there too. group_wait is short so the demo does not stall.
    helm_ upgrade --install kps prometheus-community/kube-prometheus-stack \
      --kube-context "$CTX" -n "$NS" --version "$KPS_VERSION" --wait --timeout 12m -f - >/dev/null <<'VALUES'
grafana:
  adminPassword: sovereign-demo
  defaultDashboardsEnabled: true
prometheus:
  prometheusSpec:
    retention: 6h
    # scrape ServiceMonitors from any namespace, so the mesh/gateway exporters are picked
    # up without per-namespace config.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources: { requests: { cpu: 250m, memory: 700Mi }, limits: { memory: 1400Mi } }
alertmanager:
  config:
    global:
      smtp_smarthost: 'mailpit.monitoring.svc:1025'
      smtp_from: 'alertmanager@sovereign-ai.uk.local'
      smtp_require_tls: false
    route:
      receiver: soc-email
      group_by: ['alertname']
      group_wait: 10s
      group_interval: 30s
      repeat_interval: 30m
      routes:
        - receiver: soc-email
          matchers: [ 'severity =~ ".*"' ]
    receivers:
      - name: soc-email
        email_configs:
          - to: 'soc@sovereign-ai.uk.local'
            send_resolved: true
            headers:
              subject: '[sovereign-ai] {{ .Status | toUpper }}: {{ .CommonLabels.alertname }}'
VALUES
    echo "    installed"

    echo "==> demo alert: a throwaway canary + a rule that fires when it is down"
    kc apply -n "$NS" -f - >/dev/null <<'CANARY'
apiVersion: apps/v1
kind: Deployment
metadata: { name: alert-canary, labels: { app: alert-canary } }
spec:
  replicas: 1
  selector: { matchLabels: { app: alert-canary } }
  template:
    metadata: { labels: { app: alert-canary } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
          resources: { requests: { cpu: 5m, memory: 16Mi }, limits: { memory: 32Mi } }
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: sovereign-demo-rules
  labels: { release: kps }
spec:
  groups:
    - name: sovereign.demo
      rules:
        - alert: SovereignCanaryDown
          expr: kube_deployment_status_replicas_available{namespace="monitoring",deployment="alert-canary"} == 0
          for: 1m
          labels: { severity: critical, tier: platform }
          annotations:
            summary: "Sovereign platform canary is down"
            description: "The alert-canary Deployment has no available replicas. This is the drill that proves detection routes to a person."
CANARY
    echo "    ready. Fire it with: $0 alert"
    echo
    "$0" urls
    ;;

  alert)
    echo "==> scaling the canary to zero (alert fires in ~1 min, then Alertmanager mails Mailpit)"
    kc -n "$NS" scale deploy/alert-canary --replicas=0 >/dev/null
    echo "    watch it fire:   $0 status   then   $0 mail"
    ;;

  reset)
    kc -n "$NS" scale deploy/alert-canary --replicas=1 >/dev/null
    echo "    canary restored; the alert resolves and a resolved email follows."
    ;;

  mail)
    # Read the Mailpit inbox over its API from inside the cluster, so this works with no
    # UI exposed and proves the mail actually arrived.
    echo "=== Mailpit inbox"
    kc -n "$NS" exec deploy/mailpit -- wget -qO- http://localhost:8025/api/v1/messages 2>/dev/null \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
msgs=d.get("messages",[])
print(f"  {d.get(\"total\",0)} message(s)")
for m in msgs[:8]:
    print(f"  - {m.get(\"Created\",\"\")[:19]}  {m.get(\"Subject\",\"(no subject)\")}  ->  {[t.get(\"Address\") for t in m.get(\"To\",[])]}")' \
      || echo "  (Mailpit not reachable yet)"
    ;;

  urls)
    h="$(lb_host)"
    echo "UIs (each gets its own hostname when exposed through the gateway; for now, per-service):"
    echo "  Grafana       kubectl -n $NS port-forward svc/kps-grafana 3000:80        (admin / sovereign-demo)"
    echo "  Prometheus    kubectl -n $NS port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090"
    echo "  Alertmanager  kubectl -n $NS port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093"
    echo "  Mailpit       kubectl -n $NS port-forward svc/mailpit 8025:8025"
    [ -n "$h" ] && echo "  (gateway LB: $h)"
    ;;

  status)
    kc -n "$NS" get pods 2>/dev/null || echo "  namespace not present"
    echo
    echo "=== canary replicas (0 = alert firing)"
    kc -n "$NS" get deploy alert-canary -o jsonpath='{.status.availableReplicas}{"\n"}' 2>/dev/null
    echo "=== active alerts in Alertmanager"
    kc -n "$NS" exec statefulset/alertmanager-kps-kube-prometheus-stack-alertmanager -c alertmanager -- \
      wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null \
      | python3 -c 'import json,sys
try:
    a=json.load(sys.stdin)
    for x in a: print("  -",x.get("labels",{}).get("alertname"),x.get("status",{}).get("state"))
    if not a: print("  (none)")
except Exception: print("  (alertmanager not ready)")' 2>/dev/null || echo "  (alertmanager not ready)"
    ;;

  down)
    helm_ uninstall kps -n "$NS" >/dev/null 2>&1 || true
    kc delete ns "$NS" --wait=false >/dev/null 2>&1 || true
    echo "removed"
    ;;

  *) echo "usage: $0 {up|alert|reset|mail|urls|status|down}"; exit 1 ;;
esac

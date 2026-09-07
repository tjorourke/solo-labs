#!/usr/bin/env bash
# JFrog Artifactory OSS, as an SSRF target and then as a contained one.
#
# Artifactory is a repository manager: by design it makes server-side outbound
# requests, its remote repositories proxy upstream registries. That same feature is a
# textbook SSRF primitive: point a remote repository (or its "test URL" admin call) at an
# internal address and Artifactory will connect to it for you. This script stands it up,
# then the ssrf/lockdown steps recreate the SSRF and contain it with the same layers the
# rest of the lab uses.
#
#   ./scripts/artifactory.sh up        install Artifactory OSS (platform node group)
#   ./scripts/artifactory.sh url        the in-cluster base URL
#   ./scripts/artifactory.sh creds      the admin credentials this install seeds
#   ./scripts/artifactory.sh status     what is running, and whether the waypoint is up
#   ./scripts/artifactory.sh down       remove it
#
# ORDER MATTERS, and it is the reason this is a script and not four commands. The registry
# needs an L7 waypoint in front of it (methods, not ports, are what end the message
# board), and enrolling a running, heavy stateful app in ambient mid-flight breaks its
# in-pod cert path. So: label the namespace ambient, create the waypoint, THEN install
# Artifactory into the already-ambient namespace. Only the artifactory Service is pointed
# at the waypoint, never the whole namespace: the bundled Postgres speaks a binary
# protocol and has no business going through an HTTP proxy.
#
# The SSRF recreate + block live in artifactory-ssrf.sh so this file stays the install.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=artifactory
# Pinned to the last chart that supports monolithic (single-container) Artifactory. From
# chart 107.161 the split-services layout is mandatory and deadlocks on boot on a single
# node; 107.146 (app 7.146) runs everything in one container and boots reliably.
CHART_VERSION="${ARTIFACTORY_CHART_VERSION:-107.146.35}"   # appVersion 7.146.35
# Seeded at bootstrap through the chart, so nothing in the demo needs a click-through
# password change and artifactory-ssrf.sh can authenticate on a fresh install. Override
# with ARTIFACTORY_PASSWORD if you want your own.
AR_PASS="${ARTIFACTORY_PASSWORD:-Password1!}"
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

case "${1:-status}" in
  up)
    helm_ repo add jfrog https://charts.jfrog.io >/dev/null 2>&1 || true
    helm_ repo update jfrog >/dev/null 2>&1 || true

    # baseline PSA: Artifactory's init containers chown volumes and it runs a bundled
    # Postgres, which restricted would fight. baseline is enough; the containment here is
    # the network and the gateway, not the pod profile.
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kc label ns "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null

    # Ambient BEFORE the app starts. ztunnel captures a pod on its next start, so doing
    # this now means Artifactory boots enmeshed and its cert path is never rewritten under
    # a running JVM.
    kc label ns "$NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null
    echo "    namespace $NS -> ambient (before the app starts, deliberately)"

    # The L7 waypoint, also before the app. It is an agentgateway waypoint, so it is the
    # same proxy as the front door, and 93-registry-readonly.yaml targets it later.
    kc apply -f "$LAB_ROOT/yaml/93-registry-waypoint.yaml" >/dev/null
    # Identity-based access to the bundled database, replacing the port-based NetworkPolicy
    # the Postgres subchart ships (disabled below). Read yaml/95 before changing this: a
    # NetworkPolicy naming 5432 drops every connection to a MESHED pod, because ambient
    # delivers on HBONE 15008, and the symptom is a fifteen-restart Postgres crashloop.
    kc apply -f "$LAB_ROOT/yaml/95-registry-db-authz.yaml" >/dev/null
    kc -n "$NS" wait --for=condition=Programmed gateway/artifactory-waypoint --timeout=180s >/dev/null 2>&1 \
      && echo "    waypoint artifactory-waypoint Programmed" \
      || echo "    WARNING: waypoint not Programmed yet; check 'kubectl -n $NS get gateway'" >&2

    # The chart mandates a master key and a join key. Generate them once and keep them in a
    # secret so re-runs reuse the same keys (regenerating would break an upgrade). Generated
    # at runtime, never committed.
    if ! kc -n "$NS" get secret artifactory-mandatory-keys >/dev/null 2>&1; then
      kc -n "$NS" create secret generic artifactory-mandatory-keys \
        --from-literal=master-key="$(openssl rand -hex 32)" \
        --from-literal=join-key="$(openssl rand -hex 32)" >/dev/null
      echo "    generated master/join keys (secret artifactory-mandatory-keys)"
    fi

    echo "==> Artifactory OSS $CHART_VERSION (this is a heavy unified stack; give it 5-10 min)"
    helm_ upgrade --install artifactory jfrog/artifactory \
      --kube-context "$CTX" -n "$NS" --version "$CHART_VERSION" --wait --timeout 15m \
      --set global.masterKeySecretName=artifactory-mandatory-keys \
      --set global.joinKeySecretName=artifactory-mandatory-keys \
      --set artifactory.admin.password="$AR_PASS" \
      --set serviceAccount.create=true --set serviceAccount.name=artifactory \
      --set postgresql.primary.networkPolicy.enabled=false \
      -f - >/dev/null <<'VALUES'
# Run all services in one container, the classic monolithic mode. The split-services
# layout (separate frontend/jfbus deployments) deadlocks on boot: those pods wait for the
# router's readiness while the router waits for the services they provide. Monolithic is
# the reliable OSS shape and boots far faster.
splitServicesToContainers: false
# OSS edition: the artifactory-oss image needs no license. The chart prepends the
# registry (releases-docker.jfrog.io), so repository is the path only.
artifactory:
  image:
    repository: jfrog/artifactory-oss
  # keep the whole thing on the platform node group, off the GPU and sandbox pools.
  nodeSelector:
    eks.amazonaws.com/nodegroup: platform
  persistence:
    size: 20Gi
  # hold the JVM footprint down for a demo; this is not a sizing exercise.
  extraEnvironmentVariables:
    - name: EXTRA_JAVA_OPTIONS
      value: "-Xms1g -Xmx3g"
  resources:
    requests: { cpu: "500m", memory: "3Gi" }
    limits:   { memory: "6Gi" }
# no nginx tier: reach it by ClusterIP, and later front it through agentgateway for its
# own DNS name like every other UI in the lab.
nginx:
  enabled: false
# bundled Postgres, pinned to the platform pool and kept small.
postgresql:
  enabled: true
  primary:
    nodeSelector:
      eks.amazonaws.com/nodegroup: platform
    resources:
      requests: { cpu: "150m", memory: "512Mi" }
      limits:   { memory: "1Gi" }
    persistence:
      size: 10Gi
VALUES
    kc -n "$NS" rollout status statefulset/artifactory --timeout=120s 2>/dev/null || true

    # Point the SERVICE at the waypoint, not the namespace. Callers resolve
    # http://artifactory:8082 to this Service VIP, so this is what puts their requests
    # through L7; Postgres on 5432 keeps its plain ztunnel L4 path.
    kc -n "$NS" label svc artifactory istio.io/use-waypoint=artifactory-waypoint --overwrite >/dev/null
    echo "    svc/artifactory -> waypoint (svc-scoped; postgres stays L4)"
    echo "    installed. base URL: $("$0" url)"
    echo "    admin:               $("$0" creds)"
    ;;

  url)
    echo "http://artifactory.${NS}.svc.cluster.local:8082"
    ;;

  creds)
    # Seeded by the chart at bootstrap (artifactory.admin.password), so there is no
    # first-login password change standing between a fresh install and a scripted demo.
    echo "admin / $AR_PASS"
    ;;

  status)
    kc -n "$NS" get pods -o wide --no-headers 2>/dev/null || echo "  not installed"
    echo "--- ambient + waypoint"
    kc get ns "$NS" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null | sed 's/^/  dataplane-mode: /' ; echo
    kc -n "$NS" get gateway artifactory-waypoint --no-headers 2>/dev/null | sed 's/^/  gateway: /' || echo "  gateway: none"
    kc -n "$NS" get svc artifactory -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null | sed 's/^/  svc use-waypoint: /' ; echo
    echo "--- the read-only rule (93-registry-readonly.yaml)"
    kc -n "$NS" get enterpriseagentgatewaypolicy registry-readonly --no-headers 2>/dev/null | sed 's/^/  /' || echo "  not applied (the board is still writable)"
    ;;

  down)
    helm_ uninstall artifactory -n "$NS" >/dev/null 2>&1 || true
    kc delete ns "$NS" --wait=false >/dev/null 2>&1 || true
    echo "removed"
    ;;

  *) echo "usage: $0 {up|url|creds|status|down}"; exit 1 ;;
esac

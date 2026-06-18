#!/usr/bin/env bash
# 04b-register-runtime.sh — register the Kubernetes Runtime that points the local
# arctl daemon at the kind cluster. This is platform plumbing (done by setup.sh),
# so the notebook's deploy step is a clean one-liner against an existing runtime.
#
# The daemon runs in Docker, so we join it to the kind network and feed it the
# cluster's *internal* kubeconfig (API server = the control-plane container
# hostname, reachable over that network, TLS SAN matches).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
arctl_token

# Type MUST be Kubernetes, not Kagent. A `Kagent` runtime deploys THROUGH the
# kagent controller's API, which this lab OIDC-protects (Keycloak, for the
# kagent UI SSO) — the daemon has no valid Keycloak token, so every deploy fails
# with "authentication token expired". The Kubernetes type talks to the k8s API
# with the kubeconfig and bypasses the controller's OIDC entirely, so deploys are
# reliable. Trade-off: a Kubernetes runtime isn't rendered as a "kagent platform"
# in the Runtimes UI, but the deployed agent still shows under Instances.
step "Registering the Kubernetes Runtime 'kind-kagent'"
DAEMON_CTR="$(docker ps --filter publish=12121 --format '{{.Names}}' | head -1)"
[[ -n "$DAEMON_CTR" ]] || die "arctl daemon not running (publishing :12121) — run 04-daemon.sh first"
docker network connect kind "$DAEMON_CTR" >/dev/null 2>&1 || true

RT_YAML="$(mktemp)"
{
  cat <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: kind-kagent
spec:
  type: Kubernetes
  config:
    namespace: kagent
    kubeconfig: |
EOF
  kind get kubeconfig --internal --name "$CLUSTER_NAME" | sed 's/^/      /'
} > "$RT_YAML"
arctl apply -f "$RT_YAML"; rm -f "$RT_YAML"
ok "runtime kind-kagent registered"

step "Registry hygiene (clean-slate)"
# The daemon's data survives cluster rebuilds, so it carries seeded default
# runtimes (virtual-default, kubernetes-default) and any agents/deployments from
# a previous run (e.g. a stale 'summarizer'). Drop them so the registry shows
# only the connected platforms + the catalog 04c publishes; the notebook then
# creates the agent. Keep 'local' (used by `arctl run`) and kind-kagent;
# aws-agentcore is added next by 04d.
clean_names() { arctl get "$1" 2>/dev/null | awk 'NR>1{print $1}' | sed 's#^.*/##'; }
for r in virtual-default kubernetes-default; do arctl delete runtime "$r" >/dev/null 2>&1 || true; done
for d in $(clean_names deployments); do [ -n "$d" ] && arctl delete deployment "$d" >/dev/null 2>&1 || true; done
for a in $(clean_names agents);      do [ -n "$a" ] && arctl delete agent "$a"      >/dev/null 2>&1 || true; done

step "Verifying the kagent platform is registered and reachable"
arctl get runtime kind-kagent >/dev/null 2>&1 || die "kind-kagent runtime not registered"
docker inspect "$DAEMON_CTR" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q '"kind"' \
  || die "arctl daemon is not on the kind network — it cannot reach the cluster API"
kc get nodes >/dev/null 2>&1 || die "kind cluster API not reachable"
ok "kagent platform 'kind-kagent' registered and reachable"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true

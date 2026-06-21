#!/usr/bin/env bash
# 04b-register-runtime.sh — register the kagent platform as a Kagent Runtime on the
# in-cluster AgentRegistry, so the AR UI renders it under Runtimes and deploys flow
# through the kagent controller (showing live instances). Platform plumbing (done
# by setup.sh); the notebook's deploy is then a clean one-liner.
#
# Type Kagent (not Kubernetes): a Kagent runtime deploys via the controller's HTTP
# API and FORWARDS the caller's bearer to it. Now that the registry runs IN the
# cluster, it reaches the controller by plain Service DNS (kagentUrl =
# http://kagent-controller.kagent:8083) — no NodePort hop. telemetryEndpoint points
# at the registry's own bundled collector.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
arctl_login

step "Registering the Kagent Runtime 'kind-kagent' (kagentUrl ${KAGENT_URL})"
arctl apply -f - <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: kind-kagent
spec:
  type: Kagent
  telemetryEndpoint: ${AR_TELEMETRY_ENDPOINT}
  config:
    kagentUrl: "${KAGENT_URL}"
    namespace: kagent
EOF
ok "runtime kind-kagent registered (Kagent)"

step "Registry hygiene (clean-slate)"
# The server seeds default runtimes (virtual-default, kubernetes-default) and may
# carry agents/deployments from a previous run. Drop them so the registry shows
# only the connected platforms + the catalog 04c publishes; the notebook creates
# the agent. Keep 'local' (used by `arctl run`) and kind-kagent; aws-agentcore is
# added next by 04d.
clean_names() { arctl get "$1" 2>/dev/null | awk 'NR>1{print $1}' | sed 's#^.*/##'; }
for r in virtual-default kubernetes-default; do arctl delete runtime "$r" >/dev/null 2>&1 || true; done
for d in $(clean_names deployments); do [ -n "$d" ] && arctl delete deployment "$d" >/dev/null 2>&1 || true; done
for a in $(clean_names agents);      do [ -n "$a" ] && arctl delete agent "$a"      >/dev/null 2>&1 || true; done

step "Verifying the kagent platform is registered"
arctl get runtime kind-kagent >/dev/null 2>&1 || die "kind-kagent runtime not registered"
kc -n kagent get svc kagent-controller >/dev/null 2>&1 \
  && ok "kagent controller Service present (${KAGENT_URL})" \
  || warn "kagent-controller Service not found — deploys may fail"
ok "kagent platform 'kind-kagent' registered"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true

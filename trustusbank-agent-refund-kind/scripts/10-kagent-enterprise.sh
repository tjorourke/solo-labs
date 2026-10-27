#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
set -a
source "$SECRETS_FILE" >/dev/null 2>&1
set +a
export KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
: "${KAGENT_ENT_LICENSE_KEY:?Solo Enterprise for kagent licence required}"
: "${ANTHROPIC_API_KEY:?Anthropic model key required}"
version=$KAGENT_ENT_VERSION
charts=oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts
k create namespace kagent --dry-run=client -o yaml | apply_stdin
k label namespace kagent istio.io/dataplane-mode=ambient --overwrite
tools
python3 "$LAB/scripts/enterprise-oidc.py"
printf '%s' "$KAGENT_ENT_LICENSE_KEY" | k -n kagent create secret generic trustusbank-kagent-license --from-file=enterprise-kagent-license-key=/dev/stdin --dry-run=client -o yaml | apply_stdin
printf '%s' placeholder | k -n kagent create secret generic bank-model-placeholder --from-file=ANTHROPIC_API_KEY=/dev/stdin --dry-run=client -o yaml | apply_stdin
# Use kind's standard local-path provisioner for the kagent database.
# Do not uninstall an already migrated Enterprise release on rerun.
if helm --kube-context "$CTX" list -n kagent -o json | python3 -c 'import json,sys;sys.exit(not any(r["name"]=="kagent" and r["chart"].startswith("kagent-0.") for r in json.load(sys.stdin)))'; then
  helm --kube-context "$CTX" uninstall kagent -n kagent --wait --timeout=5m
fi
helm template kagent-crds "$charts/kagent-enterprise-crds" -n kagent --version "$version" > /tmp/trustusbank-enterprise-crds-render.yaml
k apply --server-side --force-conflicts --dry-run=server -f /tmp/trustusbank-enterprise-crds-render.yaml >/dev/null
helm --kube-context "$CTX" upgrade -i kagent-crds "$charts/kagent-enterprise-crds" -n kagent --version "$version" --wait --timeout=5m
helm template kagent "$charts/kagent-enterprise" -n kagent --version "$version" -f "$LAB/yaml/kagent-enterprise-values.yaml" --set "controller.agentImage.tag=$KAGENT_RUNTIME_VERSION" > /tmp/trustusbank-enterprise-render.yaml
k apply --dry-run=server -f /tmp/trustusbank-enterprise-render.yaml >/dev/null
helm --kube-context "$CTX" upgrade -i kagent "$charts/kagent-enterprise" -n kagent --version "$version" -f "$LAB/yaml/kagent-enterprise-values.yaml" --set "controller.agentImage.tag=$KAGENT_RUNTIME_VERSION" --wait --timeout=8m
k -n kagent rollout status deploy/kagent-controller --timeout=240s
if helm --kube-context "$CTX" status bank-ui-auth -n kagent >/dev/null 2>&1; then
  helm --kube-context "$CTX" uninstall bank-ui-auth -n kagent --wait --timeout=3m
fi

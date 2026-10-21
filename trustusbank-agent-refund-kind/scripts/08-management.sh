#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
set -a
source "${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}" >/dev/null 2>&1
set +a
: "${AGENTGATEWAY_LICENSE_KEY:?agentgateway licence required}"
chart=oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management
helm show values "$chart" --version 0.5.6 >/dev/null
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | k -n agentgateway-system create secret generic trustusbank-management-license --from-file=license-key=/dev/stdin --dry-run=client -o yaml | apply_stdin
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helm template management "$chart" -n agentgateway-system --version 0.5.6 -f "$LAB/yaml/management-values.yaml" --include-crds > "$tmp/resources.yaml"
python3 - "$tmp" <<'PY'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all((p / 'resources.yaml').read_text()) if d]
for d in docs:
    if d['kind'] == 'CustomResourceDefinition':
        meta = d['metadata']
        meta.setdefault('labels', {})['app.kubernetes.io/managed-by'] = 'Helm'
        meta.setdefault('annotations', {}).update({
            'meta.helm.sh/release-name': 'management',
            'meta.helm.sh/release-namespace': 'agentgateway-system'})
for name, is_crd in [('crds', True), ('objects', False)]:
    (p / f'{name}.yaml').write_text(yaml.safe_dump_all([d for d in docs if (d['kind'] == 'CustomResourceDefinition') == is_crd]))
PY
apply "$tmp/crds.yaml"
k wait --for=condition=Established --timeout=60s -f "$tmp/crds.yaml"
k apply --dry-run=server -f "$tmp/objects.yaml" >/dev/null
helm --kube-context "$CTX" upgrade -i management "$chart" -n agentgateway-system --version 0.5.6 -f "$LAB/yaml/management-values.yaml" --wait --timeout=8m
k -n agentgateway-system rollout status deploy/solo-enterprise-ui --timeout=180s
printf 'Management UI: scripts/ui-forward.sh management, http://localhost:18390/age/\n'

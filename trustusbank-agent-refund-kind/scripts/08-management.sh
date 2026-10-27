#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
set +x
set -a
source "$SECRETS_FILE" >/dev/null 2>&1
set +a
KAGENT_ENT_LICENSE_KEY="${KAGENT_ENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
: "${KAGENT_ENT_LICENSE_KEY:?Solo Enterprise for kagent licence required}"
version=$MGMT_VERSION
chart=oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management
helm show values "$chart" --version "$version" >/dev/null
printf '%s' "$KAGENT_ENT_LICENSE_KEY" | k -n agentgateway-system create secret generic trustusbank-management-license --from-file=license-key=/dev/stdin --dry-run=client -o yaml | apply_stdin
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helm template management "$chart" -n agentgateway-system --version "$version" -f "$LAB/yaml/management-values.yaml" --include-crds > "$tmp/resources.yaml"
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
# A cold image pull plus first ClickHouse migrations exceeded eight minutes on
# a loaded development host. Leave time for the stock backend to finish.
helm --kube-context "$CTX" upgrade -i management "$chart" -n agentgateway-system --version "$version" -f "$LAB/yaml/management-values.yaml" --wait --timeout=12m
k -n agentgateway-system rollout status deploy/solo-enterprise-ui --timeout=180s
# Remove the former lab injection on upgrades too. A fresh stock pod prepares
# its own HTML from the unmodified product image.
k -n agentgateway-system get deployment solo-enterprise-ui -o json > "$tmp/ui.json"
needs_cleanup=$(python3 - "$tmp/ui.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))['spec']['template']
s = t['spec']
legacy = 'bank.trustus/ui-feedback' in t.get('metadata', {}).get('annotations', {})
legacy |= any(v['name'] == 'trustusbank-ui-feedback' for v in s.get('volumes', []))
legacy |= any(c['name'] == 'ui-frontend' and (
    c.get('lifecycle', {}).get('postStart') or any(
        m['name'] == 'trustusbank-ui-feedback' for m in c.get('volumeMounts', [])))
    for c in s['containers'])
print('true' if legacy else 'false')
PY
)
if [[ "$needs_cleanup" == true ]]; then
  patch='{"spec":{"template":{"metadata":{"annotations":{"bank.trustus/ui-feedback":null}},"spec":{"containers":[{"name":"ui-frontend","lifecycle":{"postStart":null},"volumeMounts":[{"mountPath":"/opt/trustusbank-ui","name":"trustusbank-ui-feedback","$patch":"delete"}]}],"volumes":[{"name":"trustusbank-ui-feedback","$patch":"delete"}]}}}}'
  k -n agentgateway-system patch deployment solo-enterprise-ui --type=strategic -p "$patch" --dry-run=server >/dev/null
  k -n agentgateway-system patch deployment solo-enterprise-ui --type=strategic -p "$patch"
  k -n agentgateway-system rollout status deploy/solo-enterprise-ui --timeout=180s
fi
k -n agentgateway-system delete configmap trustusbank-ui-feedback --ignore-not-found
printf 'Management UI: scripts/ui-forward.sh kagent, http://refund-lab.localhost:19380/age/\n'
